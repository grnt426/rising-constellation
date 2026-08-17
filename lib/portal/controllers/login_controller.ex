defmodule Portal.LoginController do
  use Portal, :controller

  alias RC.Accounts
  alias RC.Logs

  require Logger

  # Same bucket as the JSON login path (AuthenticationController), so
  # alternating between the two endpoints doesn't double an attacker's
  # attempt budget.
  plug(Portal.Plug.RateLimit, bucket: "auth_login", limit: 10, window_ms: 900_000)

  @doc """
  Classic HTML form login. The landing and /login LiveViews render a real
  `<form action="/login" method="post">` so password managers observe a
  conventional submit-then-navigate sequence — their save/update prompts
  hinge on it. JSON clients (SPA session bootstrap, Steam) keep using
  `POST /api/auth/identity/callback`.
  """
  def login(conn, %{"account" => account_params}) do
    login_mode = Portal.Config.fetch_key(:login_mode)
    email = account_params |> Map.get("email", "") |> String.trim()
    password = Map.get(account_params, "password", "")

    case Accounts.get_account_by_email_and_password(email, password) do
      {:ok, account} ->
        if login_mode == :disabled and account.role != :admin do
          fail(conn, "Logging in is currently disabled.")
        else
          succeed(conn, account)
        end

      {:error, reason} ->
        Logger.info("#{inspect(reason)}")
        fail(conn, "The email address is unknown or the password is wrong.")
    end
  end

  def login(conn, _params), do: fail(conn, "The email address is unknown or the password is wrong.")

  defp succeed(conn, account) do
    Logs.create_log(%{action: :login}, account)

    {:ok, access, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")
    # Tracked mint: opens a fresh rotation family for this login session.
    {:ok, refresh} = Accounts.issue_refresh_token(account)

    conn
    # sign_in puts the access token at `guardian_default_token` in session;
    # refresh sits alongside so /api/auth/refresh can read it without ever
    # exposing it to JS.
    |> RC.Guardian.Plug.sign_in(account)
    |> put_session(:refresh_token, refresh)
    # The SPA reads its Bearer token from this JS-visible cookie (see
    # front/src/plugins/auth.js), so http_only must stay false; no max-age
    # keeps it session-scoped, matching the js-cookie write it replaces.
    |> put_resp_cookie("user_token", access, http_only: false, same_site: "Lax")
    |> redirect(to: "/portal")
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: "/login")
  end
end
