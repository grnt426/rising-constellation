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
  plug Portal.Plug.RateLimit,
       [bucket: "auth_pwreset", limit: 5, window_ms: 3_600_000]
       when action in [:send_password_reset, :send_email_verification]

  # Signup is invite-only. An encrypted, 24h-expiring `invite_token` is
  # required on every request -- the token IS the proof that an existing
  # player vouched for the new account, replacing email-verification as
  # the anti-spam gate. Without a mail server hooked up, this is the
  # only signup path; the older `signup_mode == :mail_validation` branch
  # is gone from this controller (the underlying helpers remain in use
  # by the email-change flow in `update/2`).
  #
  # `signup_mode == :disabled` is still honored as a global kill-switch
  # so admins can stop ALL new accounts in an emergency, invites and all.
  def create(conn, %{"account" => account_params} = params) do
    signup_mode = Portal.Config.fetch_key(:signup_mode)
    invite_token = Map.get(params, "invite_token")

    cond do
      signup_mode == :disabled ->
        conn
        |> put_status(:forbidden)
        |> json(%{message: :signup_disabled})

      is_nil(invite_token) or invite_token == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{message: :invite_required})

      true ->
        case InviteToken.decode(Portal.Endpoint, invite_token) do
          {:ok, referrer_id} ->
            create_invited(conn, account_params, referrer_id)

          {:error, :expired} ->
            conn
            |> put_status(:bad_request)
            |> json(%{message: :invite_expired})

          {:error, _} ->
            conn
            |> put_status(:bad_request)
            |> json(%{message: :invalid_invite})
        end
    end
  end

  defp create_invited(conn, account_params, referrer_id) do
    # Strip server-controlled fields from caller input before re-adding
    # them, so a hand-crafted POST can't pre-populate `role`, `status`,
    # or `referred_by_id` independent of the invite token.
    account_params =
      account_params
      |> Map.drop(["role", "status", "referred_by_id"])
      |> Map.put("role", :user)
      |> Map.put("status", :active)
      |> Map.put("referred_by_id", referrer_id)

    case Accounts.run_signup_transaction(account_params) do
      {:ok, %{account: _account}} ->
        conn
        |> put_status(:created)
        |> json(%{message: :signup_complete})

      error ->
        Logger.error(inspect(error))
        error
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

  def send_password_reset(conn, %{"email" => email}) do
    case Accounts.send_verification(email, :password_reset) do
      {:ok, message} ->
        conn
        |> put_status(:ok)
        |> json(%{message: message})

      error ->
        error
    end
  end

  def send_email_verification(conn, %{"email" => email}) do
    case Accounts.send_verification(email, :email_verification) do
      {:ok, message} ->
        conn
        |> put_status(:ok)
        |> json(%{message: message})

      error ->
        error
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
