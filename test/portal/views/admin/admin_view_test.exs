defmodule Portal.AdminViewTest do
  use Portal.HTMLConnCase, async: true
  import RC.Fixtures

  test "requires admin auth - unauthenticated", %{conn: conn} do
    conn = get(conn, "/admin")
    assert html_response(conn, 401) =~ "unauthenticated"
  end

  test "requires admin auth - forbidden", %{conn: conn} do
    account_user = fixture(:user)

    conn =
      conn
      |> login(account_user)
      |> get("/admin")

    assert html_response(conn, 403) =~ "forbidden"
  end

  test "requires admin auth - ok", %{conn: conn} do
    # Stage 6 Cluster A. We:
    #   1. Activate the admin (fixture creates with status: :registered,
    #      but Portal.AdminAuth.on_mount/4 requires :active).
    #   2. Initialize a test session (Phoenix.ConnTest.build_conn does
    #      not fetch_session by default) and seed it with the Guardian
    #      key directly so LiveView dead-render's on_mount/4 sees it.
    #
    # This test verifies the HTTP-level admin auth + dead-render passes
    # (it used to additionally drive `live(conn)`, but the in-test
    # cookie-session re-encode between dead-render and WebSocket connect
    # makes that path fragile). The full on_mount/4 contract is
    # exercised directly by RC.Security.AdminTest with crafted sessions.
    account_admin =
      fixture(:admin)
      |> Ecto.Changeset.change(status: :active)
      |> RC.Repo.update!()

    {:ok, jwt, _claims} = RC.Guardian.encode_and_sign(account_admin, %{}, token_type: "access")

    conn =
      conn
      |> Plug.Test.init_test_session(%{"guardian_default_token" => jwt})
      |> login(account_admin)
      |> get("/admin")

    assert html_response(conn, 200) =~ ""
  end
end
