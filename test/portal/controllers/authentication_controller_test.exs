defmodule Portal.AuthenticationControllerTest do
  use Portal.APIConnCase

  import RC.Fixtures

  alias RC.Accounts

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  # Same trick as AccountControllerTest: unique synthetic IP per call so
  # the auth_login rate-limit bucket never carries over between tests.
  defp with_fresh_ip(conn) do
    n = :erlang.unique_integer([:positive])
    put_req_header(conn, "x-forwarded-for", "203.0.#{rem(div(n, 256), 256)}.#{rem(n, 256)}")
  end

  defp account_with_status(status) do
    email = "login-#{status}-#{System.unique_integer([:positive])}@email"

    {:ok, account} =
      Accounts.create_account(
        account_valid_user_attrs()
        |> Map.put(:email, email)
        |> Map.put(:status, status)
      )

    account
  end

  defp attempt_login(conn, account) do
    post(with_fresh_ip(conn), Routes.authentication_path(conn, :identity_callback),
      account: %{email: account.email, password: account_valid_user_attrs().password}
    )
  end

  describe "identity_callback by account status" do
    test "an :active account logs in", %{conn: conn} do
      conn = attempt_login(conn, account_with_status(:active))
      assert json_response(conn, 200)
    end

    test "an unverified (:registered) account logs in — it lands in the portal's read-only mode",
         %{conn: conn} do
      # The verify-email banner + Portal.Plug.VerificationGate assume the
      # unverified user is INSIDE the portal; login must let them in.
      conn = attempt_login(conn, account_with_status(:registered))
      assert json_response(conn, 200)
    end

    test "banned and inactive accounts cannot log in", %{conn: conn} do
      conn1 = attempt_login(conn, account_with_status(:banned))
      assert json_response(conn1, 401)["message"] == "account_not_found"

      conn2 =
        attempt_login(build_conn() |> put_req_header("accept", "application/json"), account_with_status(:inactive))

      assert json_response(conn2, 401)["message"] == "account_not_found"
    end
  end

  describe "classic POST /login by account status" do
    # The browser pipeline runs protect_from_forgery; the real form embeds
    # a CSRF token, tests use the standard skip flag instead.
    defp post_login(conn, account) do
      conn
      |> with_fresh_ip()
      # the browser pipeline negotiates HTML, not the module default JSON
      |> put_req_header("accept", "text/html")
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/login", account: %{email: account.email, password: account_valid_user_attrs().password})
    end

    test "an unverified (:registered) account reaches the portal", %{conn: conn} do
      conn = post_login(conn, account_with_status(:registered))
      assert redirected_to(conn) == "/portal"
    end

    test "a banned account is bounced back to /login", %{conn: conn} do
      conn = post_login(conn, account_with_status(:banned))
      assert redirected_to(conn) == "/login"
    end
  end
end
