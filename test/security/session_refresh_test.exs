defmodule RC.Security.SessionRefreshTest do
  @moduledoc """
  End-to-end regression tests for Portal.Plug.SessionRefresh — the
  server-side recovery path for sessions whose 4h access token has expired
  while the 30d refresh token is still good.

  Background: the session cookie carries BOTH tokens. Before this plug,
  any HTML request (landing page, /login, admin) made >4h after the last
  refresh hit Guardian's VerifySession error path, which dropped the whole
  session — refresh token included — and bounced the user to /login. The
  visible symptom: "I stay logged in while playing, but coming back to the
  website (or refreshing) after my computer slept logs me out."

  These tests drive real routes through the full router pipeline.
  """
  use Portal.HTMLConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.Fixtures

  alias RC.Accounts

  # Expired-at-mint access token: what a session looks like >4h after the
  # last sign-in/refresh.
  defp expired_access(account) do
    {:ok, token, _} =
      RC.Guardian.encode_and_sign(account, %{}, token_type: "access", ttl: {-60, :second})

    token
  end

  defp fresh_session(account) do
    {:ok, refresh} = Accounts.issue_refresh_token(account)
    %{guardian_default_token: expired_access(account), refresh_token: refresh}
  end

  defp activate!(account) do
    {:ok, account} = Ecto.Changeset.change(account, status: :active) |> RC.Repo.update()
    account
  end

  describe "HTML requests with an expired access token + valid refresh token" do
    test "landing page renders authenticated and the session is re-signed", %{conn: conn} do
      account = fixture(:user) |> activate!()
      session = fresh_session(account)

      conn =
        conn
        |> init_test_session(session)
        |> get("/")

      # No bounce to /login, no session drop.
      assert html_response(conn, 200)
      refute conn.private[:plug_session_info] == :drop

      # The session now carries a FRESH access token...
      new_access = get_session(conn, :guardian_default_token)
      assert is_binary(new_access)
      assert new_access != session.guardian_default_token
      assert {:ok, _} = Guardian.decode_and_verify(RC.Guardian, new_access, %{"typ" => "access"})

      # ...and the refresh token survived untouched (not rotated by the
      # passive path — rotation stays at POST /api/auth/refresh).
      assert get_session(conn, :refresh_token) == session.refresh_token
    end

    test "the request itself is authenticated (resource loaded)", %{conn: conn} do
      account = fixture(:user) |> activate!()

      conn =
        conn
        |> init_test_session(fresh_session(account))
        |> get("/")

      assert html_response(conn, 200)
      assert %RC.Accounts.Account{id: aid} = RC.Guardian.Plug.current_resource(conn)
      assert aid == account.id
    end
  end

  describe "API requests riding the session cookie" do
    test "expired session access token self-heals instead of 401ing", %{conn: conn} do
      account = fixture(:user) |> activate!()

      conn =
        conn
        |> init_test_session(fresh_session(account))
        |> put_req_header("accept", "application/json")
        |> get("/api/account")

      assert json_response(conn, 200)["id"] == account.id
    end
  end

  describe "no usable refresh token — the plug must stay out of the way" do
    test "expired access + NO refresh: bounced to /login, access token cleared", %{conn: conn} do
      account = fixture(:user) |> activate!()

      conn =
        conn
        |> init_test_session(%{guardian_default_token: expired_access(account)})
        |> get("/")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :guardian_default_token) == nil
    end

    test "the /login redirect renders cleanly (no redirect loop)", %{conn: conn} do
      account = fixture(:user) |> activate!()

      bounced =
        conn
        |> init_test_session(%{guardian_default_token: expired_access(account)})
        |> get("/")

      assert redirected_to(bounced) == "/login"

      # Follow the redirect carrying the surviving session state — the
      # cleared access token must not re-trigger the bounce.
      followed =
        build_conn()
        |> init_test_session(%{})
        |> get("/login")

      assert html_response(followed, 200)
    end

    test "expired access + REVOKED refresh (tv bump): bounced to /login", %{conn: conn} do
      account = fixture(:user) |> activate!()
      session = fresh_session(account)

      # Logout-from-another-device: every outstanding token dies.
      {:ok, _} = Accounts.invalidate_sessions(account)

      conn =
        conn
        |> init_test_session(session)
        |> get("/")

      assert redirected_to(conn) == "/login"
    end

    test "expired access + SPENT refresh (rotated away beyond grace): bounced to /login",
         %{conn: conn} do
      account = fixture(:user) |> activate!()
      session = fresh_session(account)

      {:ok, %{"jti" => jti}} =
        Guardian.decode_and_verify(RC.Guardian, session.refresh_token, %{"typ" => "refresh"})

      backdated = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      RC.Repo.update_all(
        from(rt in RC.Accounts.RefreshToken, where: rt.jti == ^jti),
        set: [rotated_at: backdated]
      )

      conn =
        conn
        |> init_test_session(session)
        |> get("/")

      # Refused (the passive path never honors a spent token) but NOT
      # flagged as theft here — no tv bump from a passive page load.
      assert redirected_to(conn) == "/login"
      assert RC.Accounts.get_account!(account.id).token_version == account.token_version
    end
  end

  describe "anonymous and healthy sessions are untouched" do
    test "no session at all: public page renders anonymously", %{conn: conn} do
      conn = get(conn, "/")
      assert html_response(conn, 200)
      assert RC.Guardian.Plug.current_resource(conn) == nil
    end

    test "valid access token: no refresh performed, token unchanged", %{conn: conn} do
      account = fixture(:user) |> activate!()
      {:ok, access, _} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")
      {:ok, refresh} = Accounts.issue_refresh_token(account)

      conn =
        conn
        |> init_test_session(%{guardian_default_token: access, refresh_token: refresh})
        |> get("/")

      assert html_response(conn, 200)
      assert get_session(conn, :guardian_default_token) == access
    end
  end
end
