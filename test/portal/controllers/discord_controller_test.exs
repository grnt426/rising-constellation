defmodule Portal.DiscordControllerTest do
  use Portal.APIConnCase
  import RC.Fixtures

  alias RC.Accounts.DiscordLinkCode
  alias RC.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  # Same trick as account_controller_test.exs — give each test a unique
  # synthetic IP so the per-IP rate limit (30/hr on discord_link_code)
  # doesn't bleed across tests.
  defp with_fresh_ip(conn) do
    n = :erlang.unique_integer([:positive])
    ip = "203.0.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
    put_req_header(conn, "x-forwarded-for", ip)
  end

  describe "POST /api/discord/link-code" do
    test "authenticated user gets a code", %{conn: conn} do
      account = fixture(:user)
      conn = conn |> with_fresh_ip() |> login(account)

      n_before = Repo.aggregate(DiscordLinkCode, :count, :id)

      conn = post(conn, "/api/discord/link-code")
      body = json_response(conn, 201)

      n_after = Repo.aggregate(DiscordLinkCode, :count, :id)

      assert is_binary(body["code"])
      assert body["expires_in_seconds"] == 300
      assert n_after == n_before + 1
    end

    test "code is bound to the requesting account", %{conn: conn} do
      account = fixture(:user)
      conn = conn |> with_fresh_ip() |> login(account)

      conn = post(conn, "/api/discord/link-code")
      %{"code" => code} = json_response(conn, 201)

      row = Repo.get_by!(DiscordLinkCode, code: code)
      assert row.account_id == account.id
      assert is_nil(row.consumed_at)
    end

    test "code matches the expected format XXXX-XXXX", %{conn: conn} do
      account = fixture(:user)
      conn = conn |> with_fresh_ip() |> login(account)

      conn = post(conn, "/api/discord/link-code")
      %{"code" => code} = json_response(conn, 201)

      assert Regex.match?(~r/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$/, code)
    end

    test "generating a new code expires any prior unconsumed codes for the account",
         %{conn: conn} do
      account = fixture(:user)
      conn = conn |> with_fresh_ip() |> login(account)

      # First mint
      conn1 = post(conn, "/api/discord/link-code")
      %{"code" => first_code} = json_response(conn1, 201)

      # Second mint
      conn2 = post(conn, "/api/discord/link-code")
      %{"code" => second_code} = json_response(conn2, 201)

      first = Repo.get_by!(DiscordLinkCode, code: first_code)
      second = Repo.get_by!(DiscordLinkCode, code: second_code)

      # First is now consumed (marked by the expire-outstanding sweep)
      refute is_nil(first.consumed_at)
      # Second is fresh
      assert is_nil(second.consumed_at)
    end

    test "unauthenticated request returns 401", %{conn: conn} do
      conn = with_fresh_ip(conn)
      conn = post(conn, "/api/discord/link-code")
      # The Guardian.Plug.EnsureAuthenticated pipeline returns 401 with
      # an empty / minimal body; assert on status, not body shape, so
      # this test doesn't tighten the contract beyond what the pipeline
      # itself promises.
      assert conn.status == 401
    end
  end
end
