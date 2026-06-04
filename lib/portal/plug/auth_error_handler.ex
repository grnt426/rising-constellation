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

  # Any token-validation rejection. Distinct from :unauthenticated — that
  # means no credential was presented, so there's nothing to clear.
  @stale_credential_errors ~w(invalid_token token_expired token_revoked
                              no_resource_found no_claims_sub no_resource_id
                              account_inactive)a

  # Subset where the credential is *permanently* dead — revoked, banned,
  # account gone, or structurally bad. The refresh token shares this fate,
  # so the session can be dropped without orphaning a still-usable refresh
  # credential. :token_expired is intentionally absent: it's the normal
  # end-of-life signal the refresh-token flow exists to recover from.
  @dead_credential_errors ~w(invalid_token token_revoked
                             no_resource_found no_claims_sub no_resource_id
                             account_inactive)a

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    accept = extract_accept(conn)
    body = to_string(type)
    code = Map.get(@codes, type, 401)
    stale? = type in @stale_credential_errors
    html? = String.contains?(accept, "text/html")

    # Drop the session when the credential is permanently dead, or on any
    # HTML stale-cred response. HTML must drop because LiveView has no
    # refresh-token flow (the user must re-login) and because not dropping
    # would loop the /login redirect below: the next request would still
    # see the same expired token in the session and bounce again.
    #
    # JSON :token_expired specifically does NOT drop the session — the
    # refresh token lives in the same session cookie, and the SPA's
    # 401-interceptor needs it to call POST /api/auth/refresh and recover
    # the access token without forcing a full re-login.
    drop? = type in @dead_credential_errors or (stale? and html?)
    conn = if drop?, do: drop_session(conn), else: conn

    cond do
      stale? and html? ->
        # /login (not request_path) so an HTML hit on /admin doesn't bounce
        # between the gate and itself. /login (not "/") so a stale-cred
        # user lands on the form that gets them back in, not the public
        # landing's sign-up CTA.
        conn |> redirect(to: "/login") |> halt()

      html? ->
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
