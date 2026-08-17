defmodule Portal.LoginControllerTest do
  use Portal.HTMLConnCase

  alias RC.Accounts

  @password "some password"

  defp account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{
        email: "login-controller@email",
        password: @password,
        hashed_password: "overwritten by the changeset",
        name: "login-ctrl-test",
        lang: "fr",
        settings: %{},
        role: :user,
        status: :active
      })
      |> Accounts.create_account()

    account
  end

  # The POST goes through :protect_from_forgery, so grab the token the
  # LiveView rendered into the form — this doubles as a regression test
  # for Portal.LiveCsrf's dead-render path.
  defp csrf_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html)
    token
  end

  describe "GET dead renders" do
    test "/login carries the full password-manager-friendly form", %{conn: conn} do
      html = conn |> get("/login") |> html_response(200)

      assert html =~ ~s(action="/login")
      assert html =~ ~s(method="post")
      assert html =~ ~s(autocomplete="username")
      assert html =~ ~s(autocomplete="current-password")
      assert html =~ ~s(data-form-type="login")
      assert html =~ ~s(name="_csrf_token")
    end

    test "/ (landing) shows the login form by default, without the old credential echo", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)

      assert html =~ ~s(action="/login")
      assert html =~ ~s(autocomplete="current-password")
      refute html =~ "data-password"
      refute html =~ "data-validated"
    end
  end

  describe "POST /login" do
    test "valid credentials sign in, set the SPA token cookie and redirect to /portal", %{conn: conn} do
      account = account_fixture()

      conn = get(conn, "/login")
      token = csrf_from(html_response(conn, 200))

      conn =
        post(conn, "/login", %{
          "_csrf_token" => token,
          "account" => %{"email" => account.email, "password" => @password}
        })

      assert redirected_to(conn) == "/portal"

      # SPA reads its Bearer token from this JS-visible cookie.
      assert %{value: jwt, http_only: false} = conn.resp_cookies["user_token"]
      assert {:ok, claims} = Guardian.decode_and_verify(RC.Guardian, jwt, %{"typ" => "access"})
      assert {:ok, resource} = RC.Guardian.resource_from_claims(claims)
      assert resource.id == account.id

      # Refresh credential stays server-side in the session.
      assert is_binary(get_session(conn, :refresh_token))
    end

    test "wrong password redirects back to /login with a flash error", %{conn: conn} do
      account = account_fixture(%{email: "wrong-pw@email"})

      conn = get(conn, "/login")
      token = csrf_from(html_response(conn, 200))

      conn =
        post(conn, "/login", %{
          "_csrf_token" => token,
          "account" => %{"email" => account.email, "password" => "not the password"}
        })

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "unknown or the password is wrong"
      assert conn.resp_cookies["user_token"] == nil
    end

    test "missing account params redirect back with a flash error", %{conn: conn} do
      conn = get(conn, "/login")
      token = csrf_from(html_response(conn, 200))

      conn = post(conn, "/login", %{"_csrf_token" => token})

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "unknown or the password is wrong"
    end
  end
end
