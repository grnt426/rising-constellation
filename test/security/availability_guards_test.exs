defmodule RC.Security.AvailabilityGuardsTest do
  @moduledoc """
  Availability guardrails on the game/forge creation surface:

    * per-account cap on concurrently active (not-ended) instances a
      user may create (`Portal.InstanceController` @max_active_instances)
    * galaxy-size cap on starting a game from an oversized scenario and
      on storing / edge-previewing oversized galaxies (`Portal.ForgeSize`)
    * per-account Hammer rate limits on forge writes
      (`Portal.Plug.AccountRateLimit`)

  Admins are exempt from every one of these (official/event games, bulk
  imports). Hammer buckets are keyed on account id, and account ids are
  unique across the test run, so buckets don't bleed between tests.
  """
  use Portal.APIConnCase, async: false

  import RC.Fixtures
  import RC.ScenarioFixtures

  alias RC.Instances
  alias RC.Repo
  alias RC.Scenarios

  @instance_attrs %{
    "description" => "some description",
    "name" => "some name",
    "opening_date" => "2010-04-17T14:00:00.000000Z",
    "registration_type" => "pre_registration",
    "registration_status" => "closed",
    "game_type" => "official",
    "public" => true,
    "start_setting" => "auto",
    "factions" => [%{"key" => "tetrarchy", "capacity" => 10}, %{"key" => "myrmezir", "capacity" => 10}]
  }

  defp create_instance_via_api(conn, account, scenario) do
    conn
    |> login(account)
    |> post(Routes.instance_path(conn, :create), %{
      instance: @instance_attrs,
      scenario_id: scenario.id
    })
  end

  defp oversized_scenario_by_metadata do
    {:ok, %{scenario: scenario}} =
      Scenarios.create_scenario(
        %{
          game_data: %{"data" => "small"},
          game_metadata: %{"system_number" => Portal.ForgeSize.max_systems() + 1},
          is_map: false
        },
        :no_thumbnail
      )

    scenario
  end

  defp oversized_scenario_by_game_data do
    systems = Enum.map(1..(Portal.ForgeSize.max_systems() + 1), fn i -> %{"key" => "s#{i}"} end)

    {:ok, %{scenario: scenario}} =
      Scenarios.create_scenario(
        %{
          game_data: %{"systems" => systems},
          game_metadata: %{},
          is_map: false
        },
        :no_thumbnail
      )

    scenario
  end

  describe "per-account active-instance cap" do
    setup [:create_account_user]

    test "4th active instance is rejected, ending one frees the slot", %{conn: conn, account: account} do
      scenario = scenario_fixture()

      created =
        for _ <- 1..3 do
          response = create_instance_via_api(conn, account, scenario)
          assert %{"id" => id} = json_response(response, 201)
          id
        end

      response = create_instance_via_api(conn, account, scenario)
      assert %{"message" => "too_many_active_instances"} = json_response(response, 403)

      # Ending a game frees its slot.
      [first_id | _] = created

      Instances.get_instance(first_id)
      |> Ecto.Changeset.change(%{state: "ended"})
      |> Repo.update!()

      response = create_instance_via_api(conn, account, scenario)
      assert json_response(response, 201)
    end

    test "admins are exempt from the cap", %{conn: conn} do
      admin = fixture(:admin)
      scenario = scenario_fixture()

      for _ <- 1..4 do
        response = create_instance_via_api(conn, admin, scenario)
        assert json_response(response, 201)
      end
    end
  end

  describe "scenario size cap at instance creation" do
    setup [:create_account_user]

    test "oversized system_number metadata is rejected for users", %{conn: conn, account: account} do
      scenario = oversized_scenario_by_metadata()

      response = create_instance_via_api(conn, account, scenario)
      assert %{"message" => "scenario_too_large"} = json_response(response, 403)
    end

    test "oversized game_data systems list is rejected for users even without metadata", %{
      conn: conn,
      account: account
    } do
      scenario = oversized_scenario_by_game_data()

      response = create_instance_via_api(conn, account, scenario)
      assert %{"message" => "scenario_too_large"} = json_response(response, 403)
    end

    test "admins may start games from oversized scenarios", %{conn: conn} do
      admin = fixture(:admin)
      scenario = oversized_scenario_by_metadata()

      response = create_instance_via_api(conn, admin, scenario)
      assert json_response(response, 201)
    end
  end

  describe "galaxy size cap on forge writes" do
    setup [:create_account_user]

    test "POST /maps rejects an oversized systems list for users", %{conn: conn, account: account} do
      systems = Enum.map(1..(Portal.ForgeSize.max_systems() + 1), fn i -> %{"key" => "s#{i}"} end)

      response =
        conn
        |> login(account)
        |> post(Routes.map_path(conn, :create),
          map: %{game_data: %{"systems" => systems}, game_metadata: %{}, is_map: true}
        )

      assert %{"message" => "galaxy_too_large"} = json_response(response, 403)
    end

    test "POST /maps/preview-edges rejects an oversized systems list before doing any work", %{
      conn: conn,
      account: account
    } do
      systems =
        Enum.map(1..(Portal.ForgeSize.max_systems() + 1), fn i ->
          %{"key" => "s#{i}", "position" => %{"x" => i, "y" => i}}
        end)

      response =
        conn
        |> login(account)
        |> post(Routes.map_path(conn, :preview_edges), systems: systems, blackholes: [])

      assert %{"message" => "galaxy_too_large"} = json_response(response, 403)
    end

    test "POST /maps/preview-edges still serves small maps", %{conn: conn, account: account} do
      systems = [
        %{"key" => "a", "position" => %{"x" => 0, "y" => 0}},
        %{"key" => "b", "position" => %{"x" => 3, "y" => 4}}
      ]

      response =
        conn
        |> login(account)
        |> post(Routes.map_path(conn, :preview_edges), systems: systems, blackholes: [])

      assert json_response(response, 200)
    end
  end

  describe "per-account forge rate limits" do
    setup [:create_account_user]

    test "map creation is limited to 10/hour per account, independent between accounts", %{
      conn: conn,
      account: account
    } do
      map_params = %{game_data: %{}, game_metadata: %{}, is_map: true}

      for n <- 1..10 do
        response =
          conn
          |> login(account)
          |> post(Routes.map_path(conn, :create), map: map_params)

        assert response.status == 201, "create #{n} unexpectedly returned #{response.status}"
      end

      response =
        conn
        |> login(account)
        |> post(Routes.map_path(conn, :create), map: map_params)

      assert response.status == 429
      assert get_resp_header(response, "retry-after") != []

      # A different account has its own bucket.
      other = fixture(:user2)

      response =
        conn
        |> login(other)
        |> post(Routes.map_path(conn, :create), map: map_params)

      assert response.status == 201
    end

    test "scenario creation is limited to 10/hour per account", %{conn: conn, account: account} do
      scenario_params = %{game_data: %{"data" => "x"}, game_metadata: %{"data" => "x"}}

      for n <- 1..10 do
        response =
          conn
          |> login(account)
          |> post(Routes.scenario_path(conn, :create), scenario: scenario_params)

        assert response.status == 201, "create #{n} unexpectedly returned #{response.status}"
      end

      response =
        conn
        |> login(account)
        |> post(Routes.scenario_path(conn, :create), scenario: scenario_params)

      assert response.status == 429
    end

    test "admins bypass the forge rate limits", %{conn: conn} do
      admin = fixture(:admin)
      map_params = %{game_data: %{}, game_metadata: %{}, is_map: true}

      for _ <- 1..11 do
        response =
          conn
          |> login(admin)
          |> post(Routes.map_path(conn, :create), map: map_params)

        assert response.status == 201
      end
    end
  end
end
