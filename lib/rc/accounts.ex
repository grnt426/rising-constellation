defmodule RC.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Argon2
  alias Ecto.Multi
  alias RC.Accounts.Account
  alias RC.Accounts.AccountToken
  alias RC.Accounts.Profile
  alias RC.Accounts.MoneyTransaction
  alias RC.Accounts.RefreshToken
  alias RC.Logs.Log
  alias RC.Repo
  alias RC.Mailer

  def run_signup_transaction(account_params) do
    Multi.new()
    |> signup_transaction(account_params, false)
    |> Repo.transaction()
  end

  def run_signup_transaction(account_params, token_params, mailer) do
    Multi.new()
    |> signup_transaction(account_params, token_params)
    |> Multi.run(:send_email, fn _repo, %{account: account, account_token: account_token} ->
      mailer.(account, account_token, :verification_template)
    end)
    |> Repo.transaction()
  end

  def run_steam_signup_transaction(account_params) do
    account =
      %Account{}
      |> Account.changeset_steam(account_params)
      |> Account.changeset_is_free(false)

    Multi.new()
    |> Multi.insert(:account, account)
    |> Multi.insert(:log, fn %{account: %Account{id: account_id}} ->
      Log.changeset(%Log{}, %{action: :create_account, account_id: account_id})
    end)
    |> Repo.transaction()
  end

  defp signup_transaction(trx, account_params, token_params) do
    account =
      %Account{}
      |> Account.changeset_is_free(false)

    trx =
      trx
      |> Multi.insert(:account, Account.changeset_password(account, account_params))
      |> Multi.insert(:log, fn %{account: %Account{id: account_id}} ->
        Log.changeset(%Log{}, %{action: :create_account, account_id: account_id})
      end)

    if token_params do
      Multi.insert(trx, :account_token, fn %{account: %Account{id: account_id}} ->
        AccountToken.changeset(%AccountToken{account_id: account_id}, token_params)
      end)
    else
      trx
    end
  end

  @doc """
  Run the transactions to update an account for a mail confirmation, password reset or email update.
  More precisely it updates the account, deletes the token and insert the corresponding log.
  If this is an email update the new email is taken in `account_token.candidate_email`.

  `log_action` should be either `email_verification` or `reset_password`
  """
  def run_account_token_update_transactions(account, account_update_params, account_token, log_action) do
    account_update_params =
      if log_action == :update_with_email,
        do: Map.put(account_update_params, "email", account_token.candidate_email),
        else: account_update_params

    multi =
      Multi.new()
      |> Multi.update(:account, Account.changeset(account, account_update_params))
      |> Multi.delete(:account_token_delete, account_token)
      |> Multi.insert(
        :log,
        fn %{account: %Account{id: account_id}} ->
          Log.changeset(%Log{account_id: account_id}, %{action: log_action})
        end
      )

    Repo.transaction(multi)
  end

  def create_account_token(attrs \\ %{}) do
    %AccountToken{}
    |> AccountToken.changeset(attrs)
    |> Repo.insert()
  end

  def create_account_token_remove_old_token_transaction(attrs) do
    Multi.new()
    |> Multi.delete_all(
      :old_token,
      from(t in AccountToken, where: t.account_id == ^attrs.account_id and t.type == ^attrs.type)
    )
    |> Multi.insert(:token, AccountToken.changeset(%AccountToken{}, attrs))
    |> Repo.transaction()
  end

  def delete_account_token(%AccountToken{} = account_token) do
    Repo.delete(account_token)
  end

  def update_account_token(%AccountToken{} = account_token, attrs) do
    account_token
    |> AccountToken.changeset(attrs)
    |> Repo.update()
  end

  def get_account_token(account_token, token_type) do
    max_validity = Application.get_env(:rc, RC.Accounts.AccountToken) |> Keyword.get(:validity_time)
    {:ok, time} = DateTime.from_unix(DateTime.to_unix(DateTime.utc_now()) - max_validity)

    Repo.one(
      from(t in AccountToken,
        where: t.value == ^account_token and t.type == ^token_type and t.inserted_at > ^time
      )
    )
  end

  @doc """
  Returns the list of accounts.

  ## Examples

      iex> list_accounts()
      [%Account{}, ...]

  """
  def list_accounts(params \\ %{}, preload_profiles? \\ false) do
    filtrex_params = Map.drop(params, ["page"])
    config = Account.filter_options()

    case Filtrex.parse_params(config, filtrex_params) do
      {:ok, filter} ->
        query =
          if preload_profiles? do
            from(a in Account, order_by: [desc: a.id], preload: :profiles)
          else
            from(a in Account, order_by: [desc: a.id])
          end

        accounts =
          Filtrex.query(query, filter)
          |> RC.Repo.paginate(params)

        {:ok, accounts}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account(123)
      %Account{}

      iex> get_account(456)
      nil

  """
  def get_account(id), do: Repo.get(Account, id)

  def get_account!(id), do: Repo.get!(Account, id)

  def get_account_preload(id) do
    from(a in Account, where: [id: ^id], preload: [:profiles, :groups, :money_transactions])
    |> Repo.one()
  end

  @doc """
  Creates a account.

  ## Examples

      iex> create_account(%{field: value})
      {:ok, %Account{}}

      iex> create_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_account(attrs \\ %{}) do
    %Account{}
    |> Account.changeset_password(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a account.

  ## Examples

      iex> update_account(account, %{field: new_value})
      {:ok, %Account{}}

      iex> update_account(account, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Admin-driven account update. Stage 6 Cluster B fix.

  Returns `{:error, :cannot_modify_peer_admin}` when the actor is an
  admin and the target is a DIFFERENT admin. Admins may still update
  their own account through this path (so an admin can edit their own
  name/lang/settings here) and may freely update non-admin accounts.

  Uses `Account.changeset_admin/2` which omits `:password` and `:steam_id`
  from the cast list — those mutations must go through the password-reset
  flow and Steam ticket flow respectively.
  """
  def admin_update_account(%Account{} = target, attrs, %Account{} = actor) do
    cond do
      target.role == :admin and target.id != actor.id ->
        {:error, :cannot_modify_peer_admin}

      true ->
        target
        |> Account.changeset_admin(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Invalidate every outstanding JWT for `account` by bumping its `token_version`.

  Used by logout, password change, account ban, etc. Bumping the column makes
  `RC.Guardian.resource_from_claims/1` reject any token whose embedded "tv"
  claim no longer matches. Cheap atomic primitive — no token store needed.
  """
  def invalidate_sessions(%Account{} = account) do
    # Rotation rows are moot once tv is bumped (the JWTs they track no
    # longer decode), but delete them anyway so the table doesn't
    # accumulate dead families.
    Repo.delete_all(from(rt in RefreshToken, where: rt.account_id == ^account.id))

    account
    |> Ecto.Changeset.change(token_version: account.token_version + 1)
    |> Repo.update()
  end

  # Two concurrent redeems of the same refresh token (multiple tabs waking
  # from sleep, retried requests) are legitimate, not theft. The loser of
  # the atomic rotation race — and any straggler re-presenting a token
  # rotated moments ago — is allowed through within this window.
  @rotation_grace_seconds 60

  @doc """
  Mint a refresh JWT for `account` and record it as the current credential
  of a new rotation family. Used at login. Returns `{:ok, token}`.
  """
  def issue_refresh_token(%Account{} = account) do
    mint_refresh_token(account, Ecto.UUID.generate())
  end

  @doc """
  Redeem a verified refresh token (its decoded `claims`) presented at
  POST /api/auth/refresh.

  Always enforces single-use: a token rotated longer than the grace window
  ago is treated as replay/theft — every outstanding token for the account
  is revoked (tv bump) and `{:error, :token_revoked}` is returned.

  `rotate?` controls whether a successor refresh token is minted:
    * `true`  — mark this token spent, return `{:ok, new_token}` in the
      same family (sliding 30-day window). Web session path and
      rotation-aware clients.
    * `false` — leave the token active and return `{:ok, nil}`. Legacy
      clients (deployed Steam builds, bot harness) that discard the
      refresh_token field of the response and keep re-presenting the
      token they got at login.

  Tokens with no tracking row (minted before the rotation table existed)
  are adopted into a fresh family on their first rotating redeem —
  RC.Guardian already rejected revoked/expired ones upstream.
  """
  def redeem_refresh_token(%Account{} = account, %{"jti" => jti} = claims, rotate?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    family = claims["fam"] || Ecto.UUID.generate()

    case Repo.get(RefreshToken, jti) do
      nil ->
        if rotate?, do: rotate_from(account, jti, family, now), else: {:ok, nil}

      %RefreshToken{rotated_at: nil} ->
        if rotate?, do: rotate_from(account, jti, family, now), else: {:ok, nil}

      %RefreshToken{rotated_at: rotated_at} ->
        redeem_rotated(account, rotated_at, family, now, rotate?)
    end
  end

  # Pre-rotation tokens carry no "jti" claim only if minted by a very old
  # Guardian config; treat them as legacy non-rotating credentials.
  def redeem_refresh_token(%Account{}, _claims, _rotate?), do: {:ok, nil}

  @doc """
  True unless this refresh token is known to have been rotated away longer
  than the grace window ago. Cheap read-only check for passive paths
  (Portal.Plug.SessionRefresh) that mint access tokens from the session's
  refresh token without redeeming it — they must not honor a spent token,
  but flagging theft is left to the refresh endpoint.
  """
  def refresh_token_current?(%{"jti" => jti}) do
    case Repo.get(RefreshToken, jti) do
      %RefreshToken{rotated_at: rotated_at} when not is_nil(rotated_at) ->
        within_rotation_grace?(rotated_at, DateTime.utc_now())

      _ ->
        true
    end
  end

  def refresh_token_current?(_claims), do: true

  # Atomically claim the rotation: only one concurrent redeem wins the
  # UPDATE; losers fall into the just-rotated grace path.
  defp rotate_from(%Account{} = account, jti, family, now) do
    {claimed, _} =
      from(rt in RefreshToken, where: rt.jti == ^jti and is_nil(rt.rotated_at))
      |> Repo.update_all(set: [rotated_at: now])

    # `claimed == 0` covers both the lost race (row just stamped by a
    # sibling request) and the legacy no-row case — for the latter there
    # is nothing to stamp and minting a tracked successor is the goal.
    case {claimed, Repo.get(RefreshToken, jti)} do
      {0, %RefreshToken{rotated_at: rotated_at}} when not is_nil(rotated_at) ->
        redeem_rotated(account, rotated_at, family, now, true)

      _ ->
        mint_refresh_token(account, family)
    end
  end

  defp redeem_rotated(%Account{} = account, rotated_at, family, now, rotate?) do
    if within_rotation_grace?(rotated_at, now) do
      if rotate?, do: mint_refresh_token(account, family), else: {:ok, nil}
    else
      # Replay of a spent token outside the race window: someone is holding
      # a credential the legitimate client already exchanged. Kill every
      # outstanding token (access + refresh, thief's and victim's alike);
      # the user re-authenticates, the thief is locked out.
      {:ok, _} = invalidate_sessions(account)
      {:error, :token_revoked}
    end
  end

  defp within_rotation_grace?(rotated_at, now),
    do: DateTime.diff(now, rotated_at) <= @rotation_grace_seconds

  defp mint_refresh_token(%Account{} = account, family) do
    {:ok, token, claims} =
      RC.Guardian.encode_and_sign(account, %{"fam" => family}, token_type: "refresh")

    %RefreshToken{}
    |> RefreshToken.changeset(%{
      jti: claims["jti"],
      account_id: account.id,
      family: family,
      expires_at: DateTime.from_unix!(claims["exp"])
    })
    |> Repo.insert!()

    # Opportunistic hygiene: rows for tokens past exp can never be
    # presented again (Guardian rejects them before any lookup).
    Repo.delete_all(
      from(rt in RefreshToken,
        where: rt.account_id == ^account.id and rt.expires_at < ^DateTime.utc_now()
      )
    )

    {:ok, token}
  end

  def update_account_money(trx, %Account{} = account, amount, reason) do
    trx
    |> Multi.update(:account_money, Ecto.Changeset.change(account, money: account.money + amount))
    |> Multi.insert(:money_transaction, fn %{account_money: %Account{id: account_id, money: money}} ->
      money_transaction = %{"amount" => amount, "money" => money, "reason" => reason, "account_id" => account_id}
      MoneyTransaction.changeset(%MoneyTransaction{}, money_transaction)
    end)
  end

  def upgrade_account(%Account{} = account, steam_id) do
    account
    |> Account.changeset(%{steam_id: steam_id})
    |> Account.changeset_is_free(false)
    |> Repo.update()
  end

  @doc """
  Updates an account and send a verification email if needed.
  """
  def update_account_transaction(
        %Account{} = account,
        account_update_params,
        token_params,
        mailer,
        email_template
      ) do
    trx =
      account_update_transaction(
        account,
        account_update_params,
        token_params,
        mailer,
        email_template
      )

    Repo.transaction(trx)
  end

  defp account_update_transaction(
         %Account{} = account,
         account_update_params,
         token_params,
         mailer,
         email_template
       ) do
    # if mail in the update and mail verification we store the candidate email in the token and send a verification email
    if token_params do
      account_update_params = Map.drop(account_update_params, ["email"])

      trx =
        Multi.new()
        |> Multi.update(:account, Account.changeset(account, account_update_params))

      if token_params,
        do:
          trx
          |> Multi.delete_all(
            :old_token,
            from(t in AccountToken, where: t.account_id == ^account.id and t.type == :email_update)
          )
          |> Multi.insert(:account_token, fn %{account: %Account{id: account_id}} ->
            AccountToken.changeset_email(%AccountToken{account_id: account_id}, token_params)
          end)
          |> Multi.run(:send_email, fn _repo, %{account: account, account_token: account_token} ->
            mailer.(account, account_token, email_template)
          end),
        else: trx
    else
      Multi.new()
      |> Multi.update(:account, Account.changeset(account, account_update_params))
    end
  end

  @doc """
  Deletes a Account.

  ## Examples

      iex> delete_account(account)
      {:ok, %Account{}}

      iex> delete_account(account)
      {:error, %Ecto.Changeset{}}

  """
  def delete_account(%Account{} = account) do
    Repo.delete(account)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking account changes.

  ## Examples

      iex> change_account(account)
      %Ecto.Changeset{source: %Account{}}

  """
  def change_account(%Account{} = account) do
    Account.changeset(account, %{})
  end

  @doc """
  Returns a list of Accounts that contains substring `search_string` in their name or email field.
  """
  def search_accounts(params, search_string) do
    pattern = "%" <> search_string <> "%"

    from(account in Account,
      where: ilike(account.email, ^pattern) or ilike(account.name, ^pattern)
    )
    |> RC.Repo.paginate(params)
  end

  @doc """
  Create a verification token and send an verification email using email provider
  """
  def send_verification(email, type) do
    token_value = AccountToken.new()

    template =
      if type == :password_reset,
        do: :password_reset_template,
        else: :verification_template

    with {:ok, account} <- get_account_by_email(email),
         {:ok, %{token: account_token}} <-
           create_account_token_remove_old_token_transaction(%{
             value: token_value,
             type: type,
             account_id: account.id
           }),
         {:ok, _} <- send_email_template(account, account_token, template) do
      if type == :password_reset,
        do: {:ok, :password_reset_sent},
        else: {:ok, :email_verification_sent}
    else
      {:error, reason} ->
        {:error, reason}

      {:error, failed_operation, failed_value, _changes_so_far} ->
        {:error, {failed_operation, failed_value}}
    end
  end

  @doc """
  Send email with given template
  """
  def send_email_template(account, token, template) do
    base_url = Application.get_env(:rc, :rc_domain)
    email_variables = get_email_variables(base_url, token, template)
    mailer_config = Application.get_env(:rc, RC.Mailer)
    sender = Keyword.get(mailer_config, :sender)
    template_id = Keyword.get(mailer_config, template)

    email =
      Swoosh.Email.new()
      |> to_destination(account, token, template)
      |> Swoosh.Email.from(sender)
      |> Swoosh.Email.put_provider_option(:template_id, template_id)
      |> Swoosh.Email.put_provider_option(:template_language, true)
      |> Swoosh.Email.put_provider_option(:variables, email_variables)

    Mailer.deliver(email)
  end

  defp get_email_variables(base_url, token, :email_update_template),
    do: %{validation_link: base_url <> "login/?action=validate-email-update&token=#{token.value}"}

  defp get_email_variables(base_url, token, :verification_template),
    do: %{validation_link: base_url <> "login/?action=validate-registration&token=#{token.value}"}

  defp get_email_variables(base_url, token, :web_bind_template),
    do: %{validation_link: base_url <> "bind/?token=#{token.value}"}

  defp get_email_variables(base_url, token, :password_reset_template),
    do: %{reset_password_link: base_url <> "reset-password/?token=#{token.value}"}

  defp to_destination(mail, account, token, :email_update_template),
    do: Swoosh.Email.to(mail, {account.name, token.candidate_email})

  defp to_destination(mail, account, token, :web_bind_template),
    do: Swoosh.Email.to(mail, {account.name, token.candidate_email})

  defp to_destination(mail, account, _token, _template),
    do: Swoosh.Email.to(mail, {account.name, account.email})

  @doc """
  Returns the list of profiles.

  ## Examples

      iex> list_profiles()
      [%Profile{}, ...]

  """
  def list_profiles(params) do
    filtrex_params = Map.drop(params, ["page", "aid"])
    config = Profile.filter_options()

    case Filtrex.parse_params(config, filtrex_params) do
      {:ok, filter} ->
        query = from(i in Profile, order_by: [desc: i.id])

        profiles =
          Filtrex.query(query, filter)
          |> RC.Repo.paginate(params)

        {:ok, profiles}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns the list of profiles.

  ## Examples

      iex> list_profiles()
      [%Profile{}, ...]

  """
  def list_profiles_by_account(params, account_id) do
    filtrex_params = Map.take(params, ["account_id"])
    config = Profile.filter_options()

    case Filtrex.parse_params(config, filtrex_params) do
      {:ok, filter} ->
        query =
          from(profile in Profile,
            as: :profile,
            left_join: registration in assoc(profile, :registrations),
            left_join: faction in assoc(registration, :faction),
            left_join: instance in assoc(faction, :instance),
            left_lateral_join:
              last in subquery(
                from(reg in RC.Instances.Registration,
                  where: [profile_id: parent_as(:profile).id],
                  order_by: [desc: reg.updated_at],
                  limit: 1,
                  select: [:id]
                )
              ),
            on: last.id == registration.id,
            preload: [registrations: {registration, faction: {faction, instance: instance}}],
            where: profile.account_id == ^account_id,
            distinct: profile.id,
            order_by: [desc: profile.id]
          )

        profiles =
          Filtrex.query(query, filter)
          |> RC.Repo.paginate(params)

        {:ok, profiles}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns a list of Profiles that contains substring `search_string` in their name or full name field.
  """
  def search_profiles(params, search_string) do
    pattern = "%" <> search_string <> "%"

    from(profile in Profile,
      where: ilike(profile.name, ^pattern) or ilike(profile.full_name, ^pattern),
      where: profile.is_bot == false
    )
    |> RC.Repo.paginate(params)
  end

  def search_profiles_in_instance(params, instance_id, search_string) do
    pattern = "%" <> search_string <> "%"

    from(profile in Profile,
      left_join: registration in assoc(profile, :registrations),
      left_join: faction in assoc(registration, :faction),
      where: faction.instance_id == ^instance_id,
      where: ilike(profile.name, ^pattern) or ilike(profile.full_name, ^pattern),
      where: profile.is_bot == false
    )
    |> RC.Repo.paginate(params)
  end

  def list_profiles_by_faction(faction_id) do
    from(profile in Profile,
      left_join: registration in assoc(profile, :registrations),
      left_join: faction in assoc(registration, :faction),
      where: faction.id == ^faction_id
    )
    |> Repo.all()
  end

  def own_profile?(account_id, profile_id) do
    Repo.exists?(
      from(p in Profile,
        join: a in Account,
        on: p.account_id == a.id,
        where: p.id == ^profile_id and a.id == ^account_id
      )
    )
  end

  @doc """
  Gets a single profile.

  Raises `Ecto.NoResultsError` if the Profile does not exist.

  ## Examples

      iex> get_profile(123)
      %Profile{}

      iex> get_profile(456)
      nil

  """
  def get_profile(id), do: Repo.get(Profile, id)

  def get_profile!(id), do: Repo.get!(Profile, id)

  def get_profile_preload(id) do
    from(profile in Profile,
      as: :profile,
      left_join: registration in assoc(profile, :registrations),
      left_join: faction in assoc(registration, :faction),
      left_join: instance in assoc(faction, :instance),
      preload: [registrations: {registration, faction: {faction, instance: instance}}],
      where: profile.id == ^id,
      distinct: profile.id,
      order_by: [desc: profile.id]
    )
    |> Repo.one()
  end

  @doc """
  Creates a profile.

  ## Examples

      iex> create_profile(%{field: value})
      {:ok, %Profile{}}

      iex> create_profile(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_profile(attrs \\ %{}) do
    %Profile{}
    |> Profile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a profile.

  ## Examples

      iex> update_profile(profile, %{field: new_value})
      {:ok, %Profile{}}

      iex> update_profile(profile, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_profile(%Profile{} = profile, attrs) do
    profile
    |> Profile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Same as `update_profile/2` but uses `Profile.update_changeset/2` which
  rejects `:account_id` and `:elo` from user-supplied attrs. Use this from
  every user-reachable endpoint (vs. `update_profile/2` which the admin
  and rating-system paths use).
  """
  def user_update_profile(%Profile{} = profile, attrs) do
    profile
    |> Profile.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Profile.

  ## Examples

      iex> delete_profile(profile)
      {:ok, %Profile{}}

      iex> delete_profile(profile)
      {:error, %Ecto.Changeset{}}

  """
  def delete_profile(%Profile{} = profile) do
    Repo.delete(profile)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking profile changes.

  ## Examples

      iex> change_profile(profile)
      %Ecto.Changeset{source: %Profile{}}

  """
  def change_profile(%Profile{} = profile) do
    Profile.changeset(profile, %{})
  end

  @doc """
  Returns :ok if the account did not reached the profile limit.
  """
  def profiles_slot_available?(account_id) do
    profiles_limit = Application.get_env(:rc, RC.Accounts.Profile) |> Keyword.get(:limit)

    case from(p in Profile, where: p.account_id == ^account_id)
         |> Repo.aggregate(:count) do
      count when count < profiles_limit -> :ok
      _ -> :error
    end
  end

  @doc """
  Returns `{:ok, account}` for a valid email and password
  """
  def get_account_by_email_and_password(nil, _), do: {:error, :invalid}
  def get_account_by_email_and_password(_, nil), do: {:error, :invalid}

  def get_account_by_email_and_password(email, password) do
    # only accept active user
    with %Account{} = account <- get_active_account_by_email(email),
         true <- Argon2.verify_pass(password, account.hashed_password) do
      {:ok, account}
    else
      _ ->
        # Help to mitigate timing attacks
        Argon2.no_user_verify()
        {:error, :unauthorized}
    end
  end

  @doc """
  Returns `{:ok, account}` for a valid email and password
  """
  def get_account_by_steam_ticket(nil, _), do: {:error, :invalid}
  def get_account_by_steam_ticket(_, nil), do: {:error, :invalid}

  def get_account_by_steam_ticket(steam_id, ticket) do
    # only accept active user; bind the lookup to the steamid Steam itself
    # verified, not the (untrusted) client-supplied one. The defensive
    # mismatch check also rejects requests where the client claims one
    # steamid but presents a ticket issued for another.
    with {:ok, verified_steam_id} <- Portal.SteamController.ticket_check(ticket),
         :ok <- check_steam_id_match(steam_id, verified_steam_id),
         %Account{} = account <- get_active_account_by_steam_id(verified_steam_id) do
      {:ok, account}
    else
      _ ->
        {:error, :unauthorized}
    end
  end

  defp check_steam_id_match(claimed, verified) do
    if to_string(claimed) == to_string(verified),
      do: :ok,
      else: {:error, :steam_id_mismatch}
  end

  defp get_active_account_by_email(email) do
    email = String.downcase(email)

    Repo.one(
      from(
        a in Account,
        where: fragment("lower(?)", a.email) == fragment("lower(?)", ^email) and a.status == "active"
      )
    )
  end

  defp get_active_account_by_steam_id(steam_id) do
    Repo.one(from(a in Account, where: a.steam_id == ^steam_id and a.status == "active"))
  end

  def get_account_by_email(email) do
    email = String.downcase(email)

    case Repo.one(
           from(
             a in Account,
             where: fragment("lower(?)", a.email) == fragment("lower(?)", ^email)
           )
         ) do
      %Account{} = account -> {:ok, account}
      _ -> {:error, "Account not found"}
    end
  end

  def get_account_by_profile(pid) do
    Repo.one(
      from(a in Account,
        join: p in Profile,
        on: p.account_id == a.id,
        where: p.id == ^pid
      )
    )
  end

  # Mute helpers — drives the silent DM drop (server-side) and surfaces
  # to the SPA via the account's settings blob for client-side chat
  # and icon filtering. `Account.settings` is JSON-encoded by Postgrex,
  # so numeric profile ids round-trip cleanly — but the map keys come
  # back as strings, hence the explicit `"muted_chat"` / `"muted_icons"`.
  # A missing settings map (older accounts) is treated as "no mutes".
  def chat_muted?(%Account{} = account, sender_profile_id),
    do: muted?(account, "muted_chat", sender_profile_id)

  def icon_muted?(%Account{} = account, placer_profile_id),
    do: muted?(account, "muted_icons", placer_profile_id)

  defp muted?(%Account{settings: settings}, key, profile_id) do
    muted = (settings || %{}) |> Map.get(key, [])
    is_list(muted) and profile_id in muted
  end
end
