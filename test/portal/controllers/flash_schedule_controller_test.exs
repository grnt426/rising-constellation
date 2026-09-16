defmodule Portal.FlashScheduleControllerTest do
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Accounts.Profile
  alias RC.FlashSchedules
  alias RC.Repo

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp schedule_params(scenario, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Tuesday Flash",
        weekday: 2,
        start_time: "20:00:00",
        scenario_ids: [scenario.id],
        game_mode_type: "ranked",
        min_players: 2,
        mutator_keys: nil
      },
      overrides
    )
  end

  describe "schedules" do
    test "admins create, edit and delete; everyone reads the list and calendar" do
      admin = fixture(:admin)
      user = fixture(:user)
      scenario = valid_scenario_fixture()

      created =
        build_conn()
        |> login(admin)
        |> post("/api/flash/schedules", %{schedule: schedule_params(scenario)})
        |> json_response(201)

      assert %{"name" => "Tuesday Flash", "weekday" => 2, "start_time" => "20:00:00"} = created
      assert [%{"name" => "test"}] = created["maps"]
      assert created["next_starts_at"]

      updated =
        build_conn()
        |> login(admin)
        |> put("/api/flash/schedules/#{created["id"]}", %{schedule: %{min_players: 4, enabled: false}})
        |> json_response(200)

      assert %{"min_players" => 4, "enabled" => false, "next_starts_at" => nil} = updated

      assert build_conn()
             |> login(user)
             |> post("/api/flash/schedules", %{schedule: schedule_params(scenario)})
             |> response(403)

      body =
        build_conn()
        |> login(user)
        |> get("/api/flash/schedules", %{from: "2030-01-01T00:00:00Z", to: "2030-01-15T00:00:00Z"})
        |> json_response(200)

      assert %{"time_zone" => "America/New_York", "schedules" => [_], "calendar" => []} = body

      assert build_conn() |> login(admin) |> delete("/api/flash/schedules/#{created["id"]}") |> response(204)
      assert FlashSchedules.list_schedules() == []
    end

    test "the calendar projects enabled schedules' weekly slots" do
      admin = fixture(:admin)
      scenario = valid_scenario_fixture()
      {:ok, _} = FlashSchedules.create_schedule(Jason.decode!(Jason.encode!(schedule_params(scenario))), admin.id)

      %{"calendar" => calendar} =
        build_conn()
        |> login(admin)
        |> get("/api/flash/schedules", %{from: "2030-01-01T00:00:00Z", to: "2030-01-15T00:00:00Z"})
        |> json_response(200)

      assert [
               %{"starts_at" => "2030-01-02T01:00:00Z", "scenario_name" => "test", "instance_id" => nil},
               %{"starts_at" => "2030-01-09T01:00:00Z"}
             ] = Enum.map(calendar, &Map.update!(&1, "starts_at", fn t -> String.replace(t, ".000000", "") end))
    end
  end

  describe "scheduled lobby" do
    setup do
      admin = fixture(:admin)
      scenario = valid_scenario_fixture()
      {:ok, _} = FlashSchedules.create_schedule(Jason.decode!(Jason.encode!(schedule_params(scenario))), admin.id)
      [match] = FlashSchedules.create_due_matches(~U[2030-01-08 23:30:00Z])

      user = fixture(:user)
      {:ok, profile} = Repo.insert(Profile.changeset(%Profile{}, %{avatar: "a", name: "Pilot", account_id: user.id}))
      instance = RC.Instances.get_instance(match.instance_id)

      %{instance: instance, user: user, profile: profile, faction: hd(instance.factions)}
    end

    test "ready locks the faction until unready; lobby state rides on the instance", ctx do
      %{instance: instance, user: user, profile: profile, faction: faction} = ctx

      assert build_conn()
             |> login(user)
             |> post("/api/registrations/profile/#{profile.id}", %{instance_id: instance.id, faction_id: faction.id})
             |> json_response(200)

      %{"scheduled" => scheduled} =
        build_conn()
        |> login(user)
        |> put("/api/flash/matches/#{instance.id}/ready", %{ready: true})
        |> json_response(200)

      assert %{"ready_count" => 1, "joined_count" => 1, "required_ready" => 2, "can_start" => false} = scheduled

      assert build_conn()
             |> login(user)
             |> put("/api/registrations/profile/#{profile.id}/cancel", %{faction_id: faction.id})
             |> json_response(400) == %{"message" => "unready_first"}

      assert [%{"ready" => true}] =
               build_conn() |> login(user) |> get("/api/instances/#{instance.id}/registrations") |> json_response(200)

      shown = build_conn() |> login(user) |> get("/api/instances/#{instance.id}") |> json_response(200)
      assert %{"status" => "open", "scheduled_start_at" => _, "blockers" => blockers} = shown["scheduled"]
      assert "not_enough_ready" in blockers

      listed = build_conn() |> login(user) |> get("/api/instances", %{state: "open"}) |> json_response(200)
      assert %{"scheduled" => %{"status" => "open"}} = Enum.find(listed, &(&1["id"] == instance.id))

      %{"message" => refusal} =
        build_conn()
        |> login(user)
        |> post("/api/flash/matches/#{instance.id}/start")
        |> json_response(400)

      assert refusal in ["before_start_time", "not_enough_ready"]

      build_conn() |> login(user) |> put("/api/flash/matches/#{instance.id}/ready", %{ready: false})

      assert build_conn()
             |> login(user)
             |> put("/api/registrations/profile/#{profile.id}/cancel", %{faction_id: faction.id})
             |> json_response(200)
    end
  end
end
