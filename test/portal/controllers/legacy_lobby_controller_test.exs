defmodule Portal.LegacyLobbyControllerTest do
  use Portal.APIConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Instances
  alias RC.Instances.{Faction, Instance}
  alias RC.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp set_instance(instance, fields) do
    from(i in Instance, where: i.id == ^instance.id) |> Repo.update_all(set: fields)
  end

  defp factions(instance) do
    from(f in Faction, where: f.instance_id == ^instance.id, order_by: f.id) |> Repo.all()
  end

  # Declares a victory through the real bookkeeping path: ranking entries
  # carry id/key/victory_points like Victory.rank_factions/1 output.
  defp declare_victory(instance, vps) do
    ranking =
      instance
      |> factions()
      |> Enum.zip(vps)
      |> Enum.sort_by(fn {_f, vp} -> -vp end)
      |> Enum.map(fn {f, vp} -> %{id: f.id, key: String.to_atom(f.faction_ref), victory_points: vp} end)

    {:ok, _} = Instances.record_victory(ranking, "victory_track")
  end

  defp lobby(conn, account) do
    conn |> login(account) |> get("/api/legacy/lobby") |> json_response(200)
  end

  describe "GET /api/legacy/lobby" do
    setup [:create_account_user]

    test "latest result is the newest official match with a victory", %{conn: conn, account: account} do
      %{instance: unofficial} = valid_instance_fixture()
      %{instance: official} = valid_instance_fixture()
      %{instance: running_official} = valid_instance_fixture()

      set_instance(unofficial, state: "ended")
      declare_victory(unofficial, [20, 1])

      set_instance(official, discord_ready: true, state: "ended")
      declare_victory(official, [3, 14])

      # Official but still running with no victory: not a result, but active.
      set_instance(running_official, discord_ready: true, state: "running")

      body = lobby(conn, account)

      assert %{"latest_result" => result, "official_active" => true, "next_official" => nil} = body
      assert result["instance_id"] == official.id
      assert result["winner_faction"] == "myrmezir"

      assert [%{"key" => "myrmezir", "rank" => 1, "victory_points" => 14}, %{"rank" => 2, "victory_points" => 3}] =
               result["factions"]

      assert result["archive_id"] == nil
    end

    test "a won official match in its post-victory tail is not active", %{conn: conn, account: account} do
      %{instance: official} = valid_instance_fixture()

      set_instance(official, discord_ready: true, state: "running")
      declare_victory(official, [9, 7])

      assert %{"latest_result" => %{"winner_faction" => "tetrarchy"}, "official_active" => false} =
               lobby(conn, account)
    end

    test "no official match gives no result and no active match", %{conn: conn, account: account} do
      assert %{"latest_result" => nil, "official_active" => false} = lobby(conn, account)
    end
  end

  describe "PUT /api/legacy/next-official" do
    test "admins set a date with an optional time, and clear it" do
      admin = fixture(:admin)

      body =
        build_conn()
        |> login(admin)
        |> put("/api/legacy/next-official", %{date: "2026-10-03", starts_at: nil})
        |> json_response(200)

      assert body["next_official"] == %{"date" => "2026-10-03", "starts_at" => nil}

      body =
        build_conn()
        |> login(admin)
        |> put("/api/legacy/next-official", %{date: "2026-10-03", starts_at: "2026-10-03T18:30:00.000Z"})
        |> json_response(200)

      assert body["next_official"] == %{"date" => "2026-10-03", "starts_at" => "2026-10-03T18:30:00Z"}
      assert RC.LegacyLobby.next_official()["starts_at"] == "2026-10-03T18:30:00Z"

      assert build_conn()
             |> login(admin)
             |> put("/api/legacy/next-official", %{date: "", starts_at: "2026-10-03T18:30:00Z"})
             |> json_response(422) == %{"message" => "date_required"}

      assert build_conn()
             |> login(admin)
             |> put("/api/legacy/next-official", %{date: "not-a-date"})
             |> json_response(422) == %{"message" => "invalid_date"}

      assert build_conn()
             |> login(admin)
             |> put("/api/legacy/next-official", %{date: ""})
             |> json_response(200) == %{"next_official" => nil}

      assert RC.LegacyLobby.next_official() == nil
    end

    test "players cannot set it", %{conn: conn} do
      user = fixture(:user)

      conn = conn |> login(user) |> put("/api/legacy/next-official", %{date: "2026-10-03"})

      assert conn.status == 403
      assert RC.LegacyLobby.next_official() == nil
    end
  end
end
