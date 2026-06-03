defmodule Portal.Plug.AuthErrorHandler do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2, redirect: 2]

  @behaviour Guardian.Plug.ErrorHandler

  @codes %{
    unauthenticated: 401,
    unauthorized: 401,
    invalid_token: 401,
    token_expired: 401,
    token_revoked: 401,
    no_resource_found: 401,
    no_claims_sub: 401,
    no_resource_id: 401,
    account_inactive: 401,
    forbidden: 403
  }

  # Errors where the credential we have on file is now bad (signature mismatch,
  # past exp, account banned, tv bumped on logout). Distinct from
  # :unauthenticated — that means no credential was presented, so there's
  # nothing to clear.
  @stale_credential_errors ~w(invalid_token token_expired token_revoked
                              no_resource_found no_claims_sub no_resource_id
                              account_inactive)a

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    accept = extract_accept(conn)
    body = to_string(type)
    code = Map.get(@codes, type, 401)
    stale? = type in @stale_credential_errors
    conn = if stale?, do: drop_session(conn), else: conn

    cond do
      stale? and String.contains?(accept, "text/html") ->
        # Redirect to "/" (not request_path) so an HTML hit on an auth-only
        # page like /admin doesn't bounce between the gate and itself.
        conn |> redirect(to: "/") |> halt()

      String.contains?(accept, "text/html") ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(code, body)
        |> halt()

      true ->
        conn
        |> put_status(code)
        |> json(%{message: body})
        |> halt()
    end
  end

  # configure_session/2 raises if the session was never fetched (future
  # Bearer-only pipelines). Today every pipeline routing here runs
  # :fetch_session first, but cheap to defend.
  defp drop_session(conn) do
    case conn.private[:plug_session_fetch] do
      :done -> configure_session(conn, drop: true)
      _ -> conn
    end
  end

  defp extract_accept(conn) do
    get_req_header(conn, "accept")
    |> case do
      [] -> ""
      [accept] -> accept
    end
    |> case do
      "" -> "text/html"
      accept -> accept
    end
  end
end
