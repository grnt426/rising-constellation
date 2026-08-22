defmodule RC.Accounts.Deletion do
  @moduledoc """
  Self-service account deletion: email-confirmed request, grace period with
  hard lockout, then scrub-in-place anonymization.

  Flow:

  1. `request_deletion/2` — password re-auth, then a confirmation email with
     a DB-backed token (1h TTL via `validity_overrides[:account_deletion]`).
  2. `confirm_deletion/1` — stamps `deletion_requested_at`, bumps
     `token_version` so every outstanding JWT (access + refresh) dies
     instantly, and records the confirmation.
  3. Grace period (`grace_days`, default 14) — `Portal.Plug.DeletionLock`
     blocks the whole authenticated API except status/cancel; login stays
     possible so the SPA can show the lockout page with "Continue Deletion
     and Logout" / "Cancel Deletion".
  4. `RC.Accounts.DeletionSweeper` calls `purge_due_accounts/0`: final
     notice email, profiles renamed `Erased-<id>` and stripped, account row
     scrubbed in place (status `:deleted`).

  Scrub-in-place is deliberate: every FK stays valid, and game artifacts
  survive under pseudonymous names — that's the compliance posture (data no
  longer relates to an identifiable person), not an oversight. Names frozen
  inside running-instance state age out with the instance snapshots and the
  30-day backup rotation.

  Steam-bound accounts without a password are rejected for now; their flow
  lands together with the Steam-auth revival.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Accounts.AccountToken
  alias RC.Accounts.DeletionRequest
  alias RC.Accounts.Emails
  alias RC.Accounts.Profile
  alias RC.Accounts.RefreshToken
  alias RC.Mailer
  alias RC.Repo

  require Logger

  def grace_days do
    Application.get_env(:rc, __MODULE__, []) |> Keyword.get(:grace_days, 14)
  end

  @doc "Whole days until purge, rounded up; nil when no deletion is pending."
  def days_until_purge(%Account{deletion_requested_at: nil}), do: nil

  def days_until_purge(%Account{deletion_requested_at: at}) do
    deadline = DateTime.add(at, grace_days() * 86_400, :second)
    max(ceil(DateTime.diff(deadline, DateTime.utc_now(), :second) / 86_400), 0)
  end

  @doc """
  Start the deletion flow: re-verify the password, then email a confirmation
  link. Returns `{:error, :deletion_pending | :steam_account |
  :invalid_password}` or the transaction result.
  """
  def request_deletion(%Account{} = account, password) do
    cond do
      account.deletion_requested_at != nil ->
        {:error, :deletion_pending}

      is_nil(account.hashed_password) ->
        {:error, :steam_account}

      not Argon2.verify_pass(password || "", account.hashed_password) ->
        {:error, :invalid_password}

      true ->
        do_request(account)
    end
  end

  defp do_request(%Account{} = account) do
    token_params = %{value: AccountToken.new(), type: :account_deletion, account_id: account.id}

    request_params = %{
      account_id: account.id,
      email_hash: email_hash(account.email),
      source: "self_service"
    }

    Multi.new()
    |> Multi.delete_all(
      :old_tokens,
      from(t in AccountToken, where: t.account_id == ^account.id and t.type == :account_deletion)
    )
    |> Multi.insert(:token, AccountToken.changeset(%AccountToken{}, token_params))
    |> Multi.insert(:request, DeletionRequest.changeset(%DeletionRequest{}, request_params))
    |> Multi.run(:email, fn _repo, %{token: token} ->
      Mailer.deliver(Emails.build(:account_deletion_template, account, token))
    end)
    |> Repo.transaction()
  end

  @doc """
  Confirm via the emailed token: start the grace period and revoke every
  outstanding session (access + refresh JWTs die with the `token_version`
  bump; the DB-side token rows follow for hygiene).
  """
  def confirm_deletion(token_value) when is_binary(token_value) do
    case Accounts.get_account_token(token_value, :account_deletion) do
      nil ->
        {:error, :invalid_token}

      %AccountToken{} = token ->
        account = Repo.get!(Account, token.account_id)
        now = DateTime.utc_now()

        result =
          Multi.new()
          |> Multi.update(
            :account,
            Ecto.Changeset.change(account,
              deletion_requested_at: now,
              token_version: account.token_version + 1
            )
          )
          |> Multi.delete_all(:tokens, from(t in AccountToken, where: t.account_id == ^account.id))
          |> Multi.delete_all(
            :refresh_tokens,
            from(r in RefreshToken, where: r.account_id == ^account.id)
          )
          |> Multi.update_all(
            :request,
            from(r in DeletionRequest,
              where: r.account_id == ^account.id and is_nil(r.confirmed_at) and is_nil(r.cancelled_at)
            ),
            set: [confirmed_at: now]
          )
          |> Repo.transaction()

        # Same as RC.Accounts.invalidate_sessions/1: kick live websockets
        # so the lockout applies now, not at the next natural disconnect.
        case result do
          {:ok, _} -> Portal.Endpoint.broadcast("portal_socket:#{account.id}", "disconnect", %{})
          _ -> :ok
        end

        result
    end
  end

  @doc "Cancel a pending deletion (the explicit button on the lockout page)."
  def cancel_deletion(%Account{deletion_requested_at: nil}), do: {:error, :not_pending}

  def cancel_deletion(%Account{} = account) do
    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(account, deletion_requested_at: nil))
    |> Multi.update_all(
      :request,
      from(r in DeletionRequest,
        where: r.account_id == ^account.id and is_nil(r.cancelled_at) and is_nil(r.purged_at)
      ),
      set: [cancelled_at: DateTime.utc_now()]
    )
    |> Repo.transaction()
  end

  @doc "Purge every account whose grace period has elapsed. Called by the sweeper."
  def purge_due_accounts do
    deadline = DateTime.add(DateTime.utc_now(), -grace_days() * 86_400, :second)

    from(a in Account,
      where:
        not is_nil(a.deletion_requested_at) and a.deletion_requested_at <= ^deadline and
          a.status != :deleted
    )
    |> Repo.all()
    |> Enum.each(fn account ->
      case purge_account(account) do
        {:ok, _} ->
          Logger.info("account deletion: purged account #{account.id}")

        {:error, step, value, _} ->
          Logger.error(
            "account deletion: purge of account #{account.id} failed at #{inspect(step)}: #{inspect(value)}"
          )
      end
    end)
  end

  @doc """
  Anonymize one account in place: strip + rename profiles, drop all tokens,
  scrub the account row. The final notice email goes out first (best-effort
  — a mail failure must never block the purge).
  """
  def purge_account(%Account{} = account) do
    try do
      Mailer.deliver(Emails.build(:account_deleted_template, account, nil))
    rescue
      e -> Logger.warning("account deletion: final notice for #{account.id} failed: #{inspect(e)}")
    end

    now = DateTime.utc_now()

    Multi.new()
    |> Multi.update_all(
      :profiles,
      from(p in Profile,
        where: p.account_id == ^account.id,
        update: [
          set: [
            name: fragment("'Erased-' || ?::text", p.id),
            full_name: nil,
            description: nil,
            long_description: nil,
            avatar: nil,
            age: nil,
            favorite_faction: nil,
            favorite_icon: nil
          ]
        ]
      ),
      []
    )
    |> Multi.delete_all(:tokens, from(t in AccountToken, where: t.account_id == ^account.id))
    |> Multi.delete_all(:refresh_tokens, from(r in RefreshToken, where: r.account_id == ^account.id))
    |> Multi.update(:account, scrub_changeset(account))
    |> Multi.update_all(
      :request,
      from(r in DeletionRequest,
        where: r.account_id == ^account.id and is_nil(r.purged_at) and is_nil(r.cancelled_at)
      ),
      set: [purged_at: now]
    )
    |> Repo.transaction()
  end

  defp scrub_changeset(%Account{id: id} = account) do
    Ecto.Changeset.change(account,
      email: "erased-#{id}@erased.invalid",
      name: "Erased-#{id}",
      # A random unguessable hash instead of nil, so every login path can
      # keep assuming the field is present.
      hashed_password: Argon2.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32))),
      steam_id: nil,
      discord_id: nil,
      mautic_contact_id: nil,
      timezone: nil,
      settings: %{},
      money: 0,
      status: :deleted,
      can_create_account_invites: false,
      token_version: account.token_version + 1
    )
  end

  defp email_hash(email) do
    :crypto.hash(:sha256, String.downcase(email)) |> Base.encode16(case: :lower)
  end
end
