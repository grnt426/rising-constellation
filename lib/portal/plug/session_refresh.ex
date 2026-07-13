defmodule Portal.Plug.SessionRefresh do
  @moduledoc """
  Server-side access-token refresh for session-carrying requests. Runs
  ahead of `Guardian.Plug.VerifySession` in `Portal.Plug.AuthAccessPipeline`.

  The Phoenix session cookie holds both the access token
  (`guardian_default_token`, 4h TTL) and the refresh token
  (`:refresh_token`, 30d TTL). Before this plug existed, a request whose
  session access token had expired went straight to the error handler —
  which, for HTML, dropped the whole session (refresh token included) and
  bounced the user to /login. Any visit to a server-rendered page more
  than 4h after the last refresh therefore destroyed the 30-day session.

  Since the server is already holding the refresh token, no client-side
  flow is needed: when the session's access token is expired (or missing)
  and the session's refresh token still verifies, re-sign the session with
  a fresh access token and let the request proceed authenticated. HTML
  pages, LiveView mounts (which read the session written here), and API
  calls riding the session cookie all recover transparently.

  Deliberately does NOT redeem/rotate the refresh token — that would cost
  a write per stale page-load and multiply rotation races across passive
  requests. Rotation stays at POST /api/auth/refresh. Spent tokens
  (rotated away beyond the grace window) are refused here via
  `RC.Accounts.refresh_token_current?/1`, but theft-flagging is likewise
  left to the refresh endpoint.

  No-ops (leaving the request to the normal Guardian pipeline) when: the
  session was never fetched, the access token still verifies, there is no
  refresh token, or the refresh token fails verification (expired, revoked
  via tv bump, wrong typ, garbage).
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with :done <- conn.private[:plug_session_fetch],
         true <- access_token_stale?(conn),
         refresh when is_binary(refresh) <- get_session(conn, :refresh_token),
         {:ok, claims} <-
           Guardian.decode_and_verify(RC.Guardian, refresh, %{"typ" => "refresh"}),
         true <- RC.Accounts.refresh_token_current?(claims),
         {:ok, account} <- RC.Guardian.resource_from_claims(claims) do
      # sign_in writes the fresh access token into the session and sets
      # the conn's current token/claims/resource, so the downstream
      # VerifySession/LoadResource plugs see an authenticated request.
      RC.Guardian.Plug.sign_in(conn, account)
    else
      _ -> conn
    end
  end

  # Stale = absent (never signed in on this session, or deleted by a prior
  # stale-credential response) with a refresh token possibly still present,
  # or present but no longer verifying (expired, tv-revoked...). The full
  # decode is cheap: local HMAC, no I/O.
  defp access_token_stale?(conn) do
    case get_session(conn, :guardian_default_token) do
      nil ->
        true

      token ->
        case Guardian.decode_and_verify(RC.Guardian, token, %{"typ" => "access"}) do
          {:ok, _claims} -> false
          {:error, _} -> true
        end
    end
  end
end
