defmodule Portal.ReportsLiveTest do
  @moduledoc """
  The /reports pages: logged-in players only (Portal.Plug.RequireAccount on
  the HTTP request, Portal.AccountAuth on every socket mount), with the
  login form sending the player back to the page they asked for.
  """
  use Portal.HTMLConnCase, async: false

  alias Portal.AccountAuth
  alias RC.Accounts
  alias RC.Repo

  @path "/reports/broken-beyond"
  @password "some password"

  defp account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{
        email: "reports-live@email",
        password: @password,
        hashed_password: "overwritten by the changeset",
        name: "reports-live-test",
        lang: "en",
        settings: %{},
        role: :user,
        status: :active
      })
      |> Accounts.create_account()

    account
  end

  defp session_for(account) do
    {:ok, token, _claims} = RC.Guardian.encode_and_sign(account, %{}, token_type: "access")
    %{"guardian_default_token" => token}
  end

  defp log_in(conn, account), do: Plug.Test.init_test_session(conn, session_for(account))

  defp csrf_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html)
    token
  end

  describe "logged out" do
    test "a visit is sent to /login and the page is remembered", %{conn: conn} do
      conn = get(conn, @path)

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :return_to) == @path
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Log in"
    end

    test "logging in from there returns to the report", %{conn: conn} do
      account = account_fixture()

      conn = get(conn, @path)
      conn = get(conn, "/login")
      token = csrf_from(html_response(conn, 200))

      conn =
        post(conn, "/login", %{
          "_csrf_token" => token,
          "account" => %{"email" => account.email, "password" => @password}
        })

      assert redirected_to(conn) == @path
      assert get_session(conn, :return_to) == nil
    end

    test "a remembered path that leaves the site is ignored", %{conn: conn} do
      account = account_fixture()

      conn =
        conn
        |> Plug.Test.init_test_session(%{return_to: "//evil.example/x"})
        |> get("/login")

      token = csrf_from(html_response(conn, 200))

      conn =
        post(conn, "/login", %{
          "_csrf_token" => token,
          "account" => %{"email" => account.email, "password" => @password}
        })

      assert redirected_to(conn) == "/portal"
    end
  end

  describe "logged in" do
    test "renders the report on the site layout", %{conn: conn} do
      html = conn |> log_in(account_fixture()) |> get(@path) |> html_response(200)

      assert html =~ "Broken Beyond"
      assert html =~ "One bot, the size of your whole faction"
      assert html =~ "The Rebellion (bot)"
      assert html =~ "Sector ownership by match day"
      # day 16.6 table by default: Tianxia's credit income then
      assert html =~ "18,084"
    end

    test "the sector chart shows who held each sector at the end", %{conn: conn} do
      html = conn |> log_in(account_fixture()) |> get(@path) |> html_response(200)

      # Dor-Valon fell on the last tick, so only the end column shows it
      assert html =~ "Dor-Valon: Myrmezir at the end"
      assert html =~ "Urqatna (Rebellion home): Rebellion at the end"
    end

    test "table headings point to numbered notes, with the credit icon", %{conn: conn} do
      html = conn |> log_in(account_fixture()) |> get(@path) |> html_response(200)

      for n <- 1..5 do
        assert html =~ ~s(href="#report-note-#{n}")
        assert html =~ ~s(id="report-note-#{n}")
      end

      assert html =~ "#resource--credit"
      refute html =~ "What changes next"
    end

    test "the table switches between day 16.6 and the end", %{conn: conn} do
      {:ok, view, html} = conn |> log_in(account_fixture()) |> live(@path)

      refute html =~ "25,070"

      html = view |> element(~s(button[phx-value-at="end"])) |> render_click()
      assert html =~ "25,070"
      refute html =~ "18,084"

      html = view |> element(~s(button[phx-value-at="freeze"])) |> render_click()
      assert html =~ "18,084"
    end

    test "an unverified account can read it", %{conn: conn} do
      account = account_fixture()
      {:ok, account} = account |> Ecto.Changeset.change(status: :registered) |> Repo.update()

      assert conn |> log_in(account) |> get(@path) |> html_response(200) =~ "Broken Beyond"
    end
  end

  describe "Portal.AccountAuth.on_mount/4" do
    test "admits an active account" do
      account = account_fixture()

      assert {:cont, socket} =
               AccountAuth.on_mount(:ensure_account, %{}, session_for(account), %Phoenix.LiveView.Socket{})

      assert socket.assigns.current_user.id == account.id
    end

    test "halts without a session token" do
      assert {:halt, _} = AccountAuth.on_mount(:ensure_account, %{}, %{}, %Phoenix.LiveView.Socket{})
    end

    test "halts a banned account whose token is still valid" do
      account = account_fixture()
      session = session_for(account)
      {:ok, _} = account |> Ecto.Changeset.change(status: :banned) |> Repo.update()

      assert {:halt, _} = AccountAuth.on_mount(:ensure_account, %{}, session, %Phoenix.LiveView.Socket{})
    end
  end
end
