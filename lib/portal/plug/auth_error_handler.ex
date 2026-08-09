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
  def auth_error(conn, {type, reason}, _opts) do
    type = normalize_type(type, reason)
    accept = extract_accept(conn)
    body = to_string(type)
    code = Map.get(@codes, type, 401)
    stale? = type in @stale_credential_errors
    html? = String.contains?(accept, "text/html")

    # Drop the whole session only when the credential is permanently dead —
    # the refresh token in the same session shares that fate (tv bump,
    # banned account, structurally bad token), so nothing is lost.
    #
    # :token_expired must NOT drop the session on either surface: the
    # still-valid refresh token lives in the same session cookie. JSON
    # callers recover via the SPA's 401-interceptor → POST /api/auth/refresh;
    # HTML normally never even gets here (Portal.Plug.SessionRefresh re-signs
    # the session upstream) — reaching this branch means the refresh token
    # was absent or unusable, so only the expired access token is cleared.
    # Deleting it is what prevents the /login redirect below from looping:
    # the next request carries no session token and renders /login cleanly.
    conn =
      cond do
        type in @dead_credential_errors -> drop_session(conn)
        stale? and html? -> delete_session_token(conn)
        true -> conn
      end

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

  # Guardian's Verify{Session,Header} plugs wrap EVERY decode failure as
  # `{:invalid_token, reason}` — a merely-expired token is distinguishable
  # from a structurally bad one only by the inner reason. Un-wrap expiry so
  # it gets the recoverable treatment: before this, the first request after
  # the 4h access TTL was classified as a dead credential and the whole
  # session — 30-day refresh token included — was dropped, which is exactly
  # the "logged out after sleep / back on the site" bug.
  defp normalize_type(:invalid_token, :token_expired), do: :token_expired
  defp normalize_type(type, _reason), do: type

  # configure_session/2 raises if the session was never fetched (future
  # Bearer-only pipelines). Today every pipeline routing here runs
  # :fetch_session first, but cheap to defend.
  defp drop_session(conn) do
    case conn.private[:plug_session_fetch] do
      :done -> configure_session(conn, drop: true)
      _ -> conn
    end
  end

  # Clear only the expired access token; the `:refresh_token` key survives
  # so the session can be re-signed later (SessionRefresh plug or the SPA's
  # refresh endpoint) instead of forcing a full re-login.
  defp delete_session_token(conn) do
    case conn.private[:plug_session_fetch] do
      :done -> delete_session(conn, :guardian_default_token)
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
