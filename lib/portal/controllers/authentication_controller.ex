defmodule Portal.AuthenticationController do
  use Portal, :controller

  alias RC.Accounts
  alias RC.Logs

  require Logger

  plug(Ueberauth)

  # 10 login attempts per IP per 15 minutes. Argon2's CPU cost alone is no
  # protection against distributed credential stuffing — the limiter is.
  plug Portal.Plug.RateLimit,
       [bucket: "auth_login", limit: 10, window_ms: 900_000]
       when action == :identity_callback

  def identity_callback(conn, %{"steam_id" => steam_id, "ticket" => ticket}) do
    case Accounts.get_account_by_steam_ticket(steam_id, ticket) do
      {:ok, account} ->
        handle_account_conn(conn, account)

      {:error, reason} ->
        Logger.info("#{inspect(reason)}")

        conn
        |> put_status(401)
        |> json(%{message: :account_not_found})
    end
  end

  def identity_callback(%{assigns: %{ueberauth_auth: %{uid: email, credentials: credentials}}} = conn, _params) do
    login_mode = Portal.Config.fetch_key(:login_mode)
    email = String.trim(email)
    password = credentials.other.password

    case Accounts.get_account_by_email_and_password(email, password) do
      {:ok, account} ->
        if login_mode == :disabled and account.role != :admin do
          conn
          |> put_status(401)
          |> json(%{message: :connection_disabled})
        else
          handle_account_conn(conn, account)
        end

      {:error, reason} ->
        Logger.info("#{inspect(reason)}")

        conn
        |> put_status(401)
        |> json(%{message: :account_not_found})
    end
  end

  def identity_callback(conn, _params) do
    conn
    |> put_status(401)
    |> json(%{message: :unauthorized})
  end

  def logout(conn, _) do
    # Bump the account's token_version BEFORE clearing the session so every
    # outstanding JWT (cookie + bearer + any captured copy) is immediately
    # rejected by RC.Guardian.resource_from_claims/1. Same `tv` check applies
    # to refresh tokens, so the long-lived credential dies here too.
    case RC.Guardian.Plug.current_resource(conn) do
      %RC.Accounts.Account{} = account -> Accounts.invalidate_sessions(account)
      _ -> :ok
    end

    conn
    |> RC.Guardian.Plug.sign_out()
    |> redirect(to: "/")
  end

  @doc """
  Swap a refresh token for a fresh access token.

  Two callers:
    * Web SPA — refresh token lives in the http-only Phoenix session, never
      reaches JS. Read via `get_session/2`.
    * Steam / bot harness — no session cookie; the client passes the refresh
      token in the JSON body.

  On success the new access token is also written back to the session, so
  LiveView mounts (which read `guardian_default_token` from session) stay
  consistent for users who navigate back to /login or /landing.
  """
  def refresh(conn, params) do
    refresh_token = get_session(conn, :refresh_token) || params["refresh_token"]

    with token when is_binary(token) <- refresh_token,
         {:ok, claims} <-
           Guardian.decode_and_verify(RC.Guardian, token, %{"typ" => "refresh"}),
         {:ok, account} <- RC.Guardian.resource_from_claims(claims),
         {:ok, access, _claims} <-
           RC.Guardian.encode_and_sign(account, %{}, token_type: "access") do
      conn
      |> RC.Guardian.Plug.sign_in(account)
      |> put_resp_header("authorization", "Bearer #{access}")
      |> json(%{access_token: access, account: account})
    else
      nil ->
        conn |> put_status(401) |> json(%{message: :no_refresh_token})

      {:error, reason} ->
        conn |> put_status(401) |> json(%{message: normalize_refresh_error(reason)})
    end
  end

  # Guardian.decode_and_verify returns `{:error, atom}` for the expected
  # rejection paths (`:token_expired`, `:invalid_token`, `:token_type_not_allowed`,
  # ...) but `{:error, %ArgumentError{}}` for completely malformed input
  # (non-base64 garbage that can't even be split into three segments).
  # Collapse the exception case down to a generic atom so the response body
  # stays a stable JSON shape.
  defp normalize_refresh_error(reason) when is_atom(reason), do: reason
  defp normalize_refresh_error(reason) when is_binary(reason), do: reason
  defp normalize_refresh_error(_), do: :invalid_token

  defp handle_account_conn(conn, account) do
    Logs.create_log(%{action: :login}, account)

    {:ok, access, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")
    {:ok, refresh, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "refresh")

    conn
    # sign_in puts the access token at `guardian_default_token` in session;
    # we stash refresh alongside it in a separate session key so the web
    # /api/auth/refresh path can read it without exposing it to JS.
    |> RC.Guardian.Plug.sign_in(account)
    |> put_session(:refresh_token, refresh)
    |> put_resp_header("authorization", "Bearer #{access}")
    |> json(%{
      # `token` kept for backwards-compat with any client still reading the
      # old key. New clients should read `access_token` and `refresh_token`.
      token: access,
      access_token: access,
      refresh_token: refresh,
      account: account
    })
  end
end
