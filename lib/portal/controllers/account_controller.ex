defmodule Portal.AccountController do
  @moduledoc """
  The Account controller.

  ### No login needed:

  Creates an Account:
      POST /accounts, body: %{account: account_params}
  Validate an Account:
      POST /accounts/validate, body: %{token: token}
  Validate email after update:
      POST /accounts/validate-update, body: %{token: token}
  Send a password verification email:
      POST /accounts/request-password-reset, body: %{email: email}
  Send a email verification:
      POST /accounts/request-email-verification, body: %{email: email}
  Update the password:
      POST /accounts/reset-password, body: %{token: token, new_password: new_password}

  ### Logged in + own resource:

  Show an account:
      GET /accounts/:aid
  Delete an account
      DELETE /accounts/:aid
  Update an account (for regular users):
      PUT /accounts/:aid, body %{account: account_params}

  ### Admin
  All routes.
  """
  use Portal, :controller

  require Logger

  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Accounts.AccountToken
  alias RC.Accounts.InviteToken
  alias RC.Logs

  action_fallback(Portal.FallbackController)

  # Rate-limit endpoints that send email on behalf of an attacker-supplied
  # address. 5 password-reset triggers per IP per hour is enough for any
  # legitimate flow and cuts off mailer-bombing.
  plug(
    Portal.Plug.RateLimit,
    [bucket: "auth_pwreset", limit: 5, window_ms: 3_600_000]
    when action in [:send_password_reset, :send_email_verification]
  )

  plug(
    Portal.Plug.RateLimit,
    [bucket: "signup", limit: 10, window_ms: 3_600_000]
    when action in [:create]
  )

  # Signup is open with mandatory email verification: accounts start as
  # `:registered` and get a verification email; until the link is clicked
  # the account is read-only (Portal.Plug.VerificationGate) — it can only
  # set up its own profile, so throwaway signups can't touch the service.
  #
  # An `invite_token` is now optional and only credits the referrer
  # (`referred_by_id`) — it no longer bypasses email verification, since
  # invite links are shareable and the email gate is the anti-spam floor.
  # A bad or expired referral link doesn't block signup.
  #
  # `signup_mode == :disabled` is still honored as a global kill-switch
  # so admins can stop ALL new accounts in an emergency.
  #
  # When Portal.Captcha is enabled (prod), the request must also carry a
  # solved proof-of-work payload — scripts that POST here directly have
  # to burn CPU per attempt.
  #
  # Email collisions are never revealed (enumeration hardening): a signup
  # against a taken address returns the same :signup_complete as a fresh
  # one. What actually happens depends on the holder — see
  # create_with_collision_handling/3.
  def create(conn, %{"account" => account_params} = params) do
    cond do
      Portal.Config.fetch_key(:signup_mode) == :disabled ->
        conn
        |> put_status(:forbidden)
        |> json(%{message: :signup_disabled})

      not captcha_valid?(params) ->
        conn
        |> put_status(:forbidden)
        |> json(%{message: :captcha_failed})

      true ->
        # Strip server-controlled fields from caller input before re-adding
        # them, so a hand-crafted POST can't pre-populate `role`, `status`,
        # or `referred_by_id`.
        account_params =
          account_params
          |> Map.drop(["role", "status", "referred_by_id"])
          |> Map.put("role", :user)
          |> Map.put("status", :registered)
          |> Map.put("referred_by_id", decode_referrer(Map.get(params, "invite_token")))

        token_params = %{value: AccountToken.new(), type: :email_verification}
        create_with_collision_handling(conn, account_params, token_params)
    end
  end

  defp captcha_valid?(params) do
    not Portal.Captcha.enabled?() or Portal.Captcha.verify(params["captcha"]) == :ok
  end

  # Route the signup by what already holds the address:
  #
  #   * nobody             → plain signup (verification email);
  #   * an unverified user → reclaim: the squatting `:registered` row is
  #     replaced wholesale by this registrant (the mailbox click is the
  #     true arbiter of ownership, so the 7-day expiry wait is dropped);
  #   * anyone else        → courtesy "you already have an account" email
  #     to the existing address, and the same :signup_complete response.
  #
  # Every email the collision paths can send is attacker-triggerable at
  # will (unlike first signup, which uniqueness bounds to one send), so
  # they all consume the per-recipient cap — once capped, the response
  # stays uniform but nothing is sent or reclaimed.
  defp create_with_collision_handling(conn, account_params, token_params) do
    case existing_account(account_params["email"]) do
      nil ->
        do_signup(conn, account_params, token_params)

      %Account{status: :registered, role: :user, is_bot: false, steam_id: nil} = squatter ->
        reclaim_signup(conn, squatter, account_params, token_params)

      %Account{} = existing ->
        notify_existing_account(conn, existing, account_params)
    end
  end

  defp existing_account(email) when is_binary(email) and email != "" do
    case Accounts.get_account_by_email(email) do
      {:ok, account} -> account
      _ -> nil
    end
  end

  defp existing_account(_), do: nil

  defp do_signup(conn, account_params, token_params) do
    case Accounts.run_signup_transaction(account_params, token_params, signup_mailer()) do
      {:ok, %{account: _account}} ->
        signup_complete(conn)

      # Lost a race with a concurrent signup for the same address: the
      # collision pre-check said free but the unique index disagreed.
      # Fold into the uniform response rather than leaking "taken".
      {:error, :account, %Ecto.Changeset{} = changeset, _} = error ->
        if email_taken?(changeset) do
          signup_complete(conn)
        else
          Logger.error(inspect(error))
          error
        end

      {:error, :send_email, _reason, _} = error ->
        email_send_failed(conn, error)

      error ->
        Logger.error(inspect(error))
        error
    end
  end

  # The provider refused the verification email (e.g. SES still in the
  # sandbox rejecting unverified recipients, quota, outage). The
  # transaction rolled back — no account exists — so tell the user
  # plainly instead of letting the raw multi tuple 500 downstream.
  defp email_send_failed(conn, error) do
    Logger.error("signup verification email failed: #{inspect(error)}")

    conn
    |> put_status(502)
    |> json(%{message: :email_send_failed})
  end

  # Test seam: config :rc, :signup_mailer (a 3-arity fun) replaces the
  # real sender so mail-provider failures can be simulated end-to-end.
  defp signup_mailer do
    Application.get_env(:rc, :signup_mailer) || (&Accounts.send_email_template/3)
  end

  defp reclaim_signup(conn, squatter, account_params, token_params) do
    changeset = Account.changeset_password(%Account{}, account_params)

    cond do
      # Same errors a free-address signup would get (the changeset can't
      # see email uniqueness, which is the one thing we're hiding).
      not changeset.valid? ->
        {:error, changeset}

      not recipient_allowed?(account_params["email"]) ->
        signup_complete(conn)

      true ->
        case Accounts.run_reclaim_signup_transaction(
               squatter,
               account_params,
               token_params,
               signup_mailer()
             ) do
          {:ok, %{account: _account}} ->
            signup_complete(conn)

          {:error, :send_email, _reason, _} = error ->
            email_send_failed(conn, error)

          error ->
            Logger.error(inspect(error))
            error
        end
    end
  end

  defp notify_existing_account(conn, existing, account_params) do
    changeset = Account.changeset_password(%Account{}, account_params)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      recipient_allowed?(existing.email) ->
        case Accounts.send_email_template(existing, nil, :existing_account_template) do
          {:ok, _} -> :ok
          error -> Logger.warning("courtesy existing-account email failed: #{inspect(error)}")
        end

        signup_complete(conn)

      true ->
        signup_complete(conn)
    end
  end

  defp signup_complete(conn) do
    conn
    |> put_status(:created)
    |> json(%{message: :signup_complete})
  end

  defp email_taken?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :email) do
      {_msg, meta} -> Keyword.get(meta, :constraint) == :unique
      _ -> false
    end
  end

  defp decode_referrer(token) when token in [nil, ""], do: nil

  defp decode_referrer(invite_token) do
    case InviteToken.decode(Portal.Endpoint, invite_token) do
      {:ok, referrer_id} -> referrer_id
      {:error, _} -> nil
    end
  end

  def index(conn, params) do
    case Accounts.list_accounts(params, true) do
      {:ok, accounts} ->
        conn
        |> Scrivener.Headers.paginate(accounts)
        |> render("index.json", accounts: accounts)

      {:error, _reason} ->
        conn
        |> put_status(400)
        |> json(%{message: :params_error})
    end
  end

  def show(conn, %{"aid" => id}) do
    case Accounts.get_account(id) do
      nil -> {:error, :not_found}
      account -> render(conn, "show.json", account: account)
    end
  end

  def get_own_account(conn, _params) do
    case Accounts.get_account(conn.private.guardian_default_resource.id) do
      nil -> {:error, :not_found}
      account -> render(conn, "show.json", account: account)
    end
  end

  # --- Self-service account deletion (RC.Accounts.Deletion) -----------------

  @deletion_request_window_ms 24 * 60 * 60 * 1000
  @deletion_request_limit 5

  def request_deletion(conn, params) do
    account = conn.private.guardian_default_resource

    with {:allow, _} <-
           Hammer.check_rate(
             "deletion-request:#{account.id}",
             @deletion_request_window_ms,
             @deletion_request_limit
           ),
         {:ok, _} <- RC.Accounts.Deletion.request_deletion(account, params["password"]) do
      json(conn, %{status: "confirmation_sent"})
    else
      {:deny, _} ->
        conn |> put_status(:too_many_requests) |> json(%{message: :too_many_requests})

      {:error, :invalid_password} ->
        conn |> put_status(:forbidden) |> json(%{message: :invalid_password})

      {:error, :steam_account} ->
        conn |> put_status(:conflict) |> json(%{message: :steam_account_deletion_unsupported})

      {:error, :deletion_pending} ->
        conn |> put_status(:conflict) |> json(%{message: :deletion_pending})

      other ->
        other
    end
  end

  def confirm_deletion(conn, %{"token" => token}) do
    case RC.Accounts.Deletion.confirm_deletion(token) do
      {:ok, %{account: account}} ->
        json(conn, %{
          status: "deletion_pending",
          days_left: RC.Accounts.Deletion.days_until_purge(account),
          grace_days: RC.Accounts.Deletion.grace_days()
        })

      {:error, :invalid_token} ->
        conn |> put_status(:bad_request) |> json(%{message: :invalid_or_expired_token})

      other ->
        other
    end
  end

  def cancel_deletion(conn, _params) do
    account = conn.private.guardian_default_resource

    case RC.Accounts.Deletion.cancel_deletion(account) do
      {:ok, _} ->
        json(conn, %{status: "deletion_cancelled"})

      {:error, :not_pending} ->
        conn |> put_status(:conflict) |> json(%{message: :not_pending})

      other ->
        other
    end
  end

  def deletion_status(conn, _params) do
    account = conn.private.guardian_default_resource

    case account.deletion_requested_at do
      nil ->
        json(conn, %{status: "none"})

      requested_at ->
        json(conn, %{
          status: "deletion_pending",
          requested_at: requested_at,
          days_left: RC.Accounts.Deletion.days_until_purge(account),
          grace_days: RC.Accounts.Deletion.grace_days()
        })
    end
  end

  def update_restricted(conn, %{"aid" => aid, "account" => account_params}) do
    update(conn, %{"aid" => aid, "account" => Map.drop(account_params, ["role", "status"])})
  end

  def update(conn, %{"aid" => aid, "account" => account_params}) do
    signup_mode = Portal.Config.fetch_key(:signup_mode)

    email_update? = Map.has_key?(account_params, "email")
    actor = conn.private.guardian_default_resource

    case Accounts.get_account(aid) do
      nil ->
        {:error, :not_found}

      # Stage 6 Cluster B fix. Admin-on-peer-admin is forbidden — even
      # the actor's password reset / email change goes through the same
      # flow we'd give a regular user. The actor can still edit their
      # own account here (target.id == actor.id), and can manage
      # non-admin accounts freely.
      %Account{role: :admin} = account when account.id != actor.id ->
        Logs.create_log(%{action: :update_restricted}, account)

        conn
        |> put_status(403)
        |> json(%{message: :cannot_modify_peer_admin})

      account ->
        # Log
        if account.role == :admin,
          do: Logs.create_log(%{action: :update}, account),
          else: Logs.create_log(%{action: :update_restricted}, account)

        # Stage 6 Cluster B fix. Strip `:password` and `:steam_id` from
        # the params before calling the transaction helper. The helper
        # itself still uses `Account.changeset/2` so the email-verification
        # flow (token_params branch below) keeps working for the
        # admin-edits-own-email case — but the dangerous fields are now
        # filtered before they ever reach the changeset.
        account_params = Map.drop(account_params, ["password", "steam_id"])

        token_params =
          if email_update? and signup_mode == :email_verification,
            do: %{
              value: AccountToken.new(),
              type: :email_update,
              candidate_email: account_params["email"]
            },
            else: nil

        case Accounts.update_account_transaction(
               account,
               account_params,
               token_params,
               &Accounts.send_email_template/3,
               :email_update_template
             ) do
          {:ok, %{account: account}} ->
            render(conn, "show.json", account: account)

          {:error, :send_email,
           {_error_status_code,
            %{
              "Errors" => reason,
              "Status" => status
            }}, _} ->
            Logger.error("#{inspect(status)}, #{inspect(reason)}")

            conn
            |> put_status(502)
            |> json(%{message: :general_error})

          {:error, :send_email,
           {_error_code, %{"ErrorIdentifier" => _error_id, "ErrorMessage" => reason, "StatusCode" => status}}, _} ->
            Logger.error("#{inspect(status)}, #{inspect(reason)}")

            conn
            |> put_status(502)
            |> json(%{message: :general_error})

          {:error, :connect_timeout, _, _} ->
            conn
            |> put_status(502)
            |> json(%{message: :mailjet_connect_timeout})

          error ->
            error
        end
    end
  end

  def update_settings(conn, %{"settings" => _settings} = attrs) do
    account_id = conn.private.guardian_default_resource.id
    {lang, settings} = attrs["settings"] |> Map.pop("lang")

    account = Accounts.get_account!(account_id)

    case Accounts.update_account(account, %{lang: lang, settings: settings}) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> json(%{account: :updated})

      error ->
        error
    end
  end

  def validate(conn, %{"token" => token}) do
    case Accounts.get_account_token(token, :email_verification) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{message: :bad_or_expired_token})

      token ->
        case Accounts.get_account(token.account_id) do
          nil ->
            {:error, :not_found}

          account ->
            account_update_attrs = %{status: :active}

            case Accounts.run_account_token_update_transactions(
                   account,
                   account_update_attrs,
                   token,
                   :account_validation
                 ) do
              {:ok, _} ->
                conn
                |> put_status(:ok)
                |> json(%{message: :account_validated})

              error ->
                error
            end
        end
    end
  end

  def validate_update(conn, %{"token" => token}) do
    case Accounts.get_account_token(token, :email_update) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{message: :bad_or_expired_token})

      token ->
        case Accounts.get_account(token.account_id) do
          nil ->
            {:error, :not_found}

          account ->
            case Accounts.run_account_token_update_transactions(account, %{}, token, :update_with_email) do
              {:ok, _} ->
                conn
                |> put_status(:ok)
                |> json(%{message: :account_email_updated})

              error ->
                error
            end
        end
    end
  end

  def reset_password(conn, %{"token" => token, "new_password" => new_password}) do
    case Accounts.get_account_token(token, :password_reset) do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{message: :bad_or_expired_token})

      token ->
        case Accounts.get_account(token.account_id) do
          nil ->
            {:error, :not_found}

          %{status: :registered} ->
            conn
            |> put_status(403)
            |> json(%{message: :account_not_confirmed})

          account ->
            account_update_attrs = %{password: new_password}

            # TRX
            case Accounts.run_account_token_update_transactions(account, account_update_attrs, token, :reset_password) do
              {:ok, _} ->
                conn
                |> put_status(:ok)
                |> json(%{message: :password_reseted})

              error ->
                error
            end
        end
    end
  end

  # Per-recipient cap for the endpoints that email attacker-chosen
  # addresses. The per-IP RateLimit plug alone doesn't stop an attacker
  # who rotates source IPs from bombing one victim's inbox with our
  # domain's mail (harassment for them, SES-reputation damage for us).
  # 3 emails per address per day is plenty for any legitimate
  # reset/resend loop. Counted per request, before the account lookup,
  # so it also throttles enumeration probing.
  @recipient_window_ms 24 * 60 * 60 * 1000
  @recipient_limit 3

  defp recipient_allowed?(email) do
    key = "mail-to:" <> String.downcase("#{email}")

    case Hammer.check_rate(key, @recipient_window_ms, @recipient_limit) do
      {:allow, _count} -> true
      {:deny, _limit} -> false
    end
  end

  # Both senders answer the same 200 whether or not the address has an
  # account (enumeration hardening) — an unknown recipient or a send
  # failure is logged, never revealed. The 429s stay: they key off the
  # caller's IP / the recipient's daily budget, not account existence.
  def send_password_reset(conn, %{"email" => email}) do
    send_uniformly(conn, email, :password_reset, :password_reset_sent)
  end

  def send_email_verification(conn, %{"email" => email}) do
    send_uniformly(conn, email, :email_verification, :email_verification_sent)
  end

  defp send_uniformly(conn, email, type, message) do
    if recipient_allowed?(email) do
      case Accounts.send_verification(email, type) do
        {:ok, _message} -> :ok
        error -> Logger.info("#{type} for #{inspect(email)} not sent: #{inspect(error)}")
      end

      conn
      |> put_status(:ok)
      |> json(%{message: message})
    else
      conn
      |> put_status(:too_many_requests)
      |> json(%{message: :rate_limited})
    end
  end

  def delete(conn, %{"aid" => aid}) do
    case Accounts.get_account(aid) do
      nil ->
        {:error, :not_found}

      account ->
        with {:ok, %Account{}} <- Accounts.delete_account(account) do
          send_resp(conn, :no_content, "")
        end
    end
  end
end
