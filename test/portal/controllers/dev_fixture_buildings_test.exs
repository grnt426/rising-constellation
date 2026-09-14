defmodule Portal.DevFixtureBuildingsTest do
  @moduledoc """
  POST /api/harness/dev/agent-fixture with `empire: {"buildings": true}`
  (help-manual Buildings screenshots), and the dev-only
  `{:dev_put_building, ...}` call of `Instance.StellarSystem.Agent` it
  relies on. One full instance boot (tag `:dev_fixture`):

      MIX_ENV=test mix test test/portal/controllers/dev_fixture_buildings_test.exs
  """
  use Portal.APIConnCase, async: false

  alias RC.Accounts.Profile

  @moduletag timeout: 300_000
  @moduletag :dev_fixture

  @path "/api/harness/dev/agent-fixture"
  @secret "dev-fixture-test-secret"

  setup do
    prev_env = Application.get_env(:rc, :environment)
    prev_secret = Application.get_env(:rc, :bot_harness_secret)
    Application.put_env(:rc, :environment, :dev)
    Application.put_env(:rc, :bot_harness_secret, @secret)

    on_exit(fn ->
      Application.put_env(:rc, :environment, prev_env)
      Application.put_env(:rc, :bot_harness_secret, prev_secret)
    end)

    # the controller's default caller and its two hard-wired puppets
    accounts =
      Map.new(1..3, fn n ->
        {:ok, account} =
          RC.Fixtures.create_account(%{
            email: "user#{n}@abc",
            hashed_password: "some hashed_password",
            password: "some password",
            name: "fixture user #{n}",
            role: :user,
            status: :active
          })

        {n, account}
      end)

    {:ok, user1: accounts[1]}
  end

  test "buildings: home's planet gets its buildings, a damaged one and a two-order queue", %{
    conn: conn,
    user1: account
  } do
    body =
      conn
      |> post_fixture(%{"email" => "user1@abc", "speed" => "slow", "empire" => %{"buildings" => true}})
      |> json_response(200)

    iid = body["instance_id"]
    pid = RC.Repo.get_by!(Profile, account_id: account.id).id
    home = body["system"]["id"]

    try do
      b = body["empire"]["buildings"]
      assert is_map(b), "no buildings block: #{inspect(body["empire"])}"
      uid = b["body_uid"]
      idle = b["idle"]["tile"]
      damaged = b["damaged"]["tile"]
      [q1, q2] = Enum.map(b["queued"], & &1["tile"])
      assert length(Enum.uniq([1, idle, damaged, q1, q2])) == 5
      assert b["free_tiles"] != []

      {:ok, system} = Game.call(iid, :stellar_system, home, :get_state)
      planet = Enum.find(system.bodies, &(&1.uid == uid))
      assert planet.type == :habitable_planet
      tile = fn id -> Enum.find(planet.tiles, &(&1.id == id)) end

      assert %{building_key: :infra_open, building_level: 2, building_status: :built, construction_status: :none} =
               tile.(1)

      assert %{building_key: :hab_open, building_level: 1, building_status: :built, construction_status: :none} =
               tile.(idle)

      assert %{building_key: :university_open, building_level: 1, building_status: :damaged} = tile.(damaged)
      assert %{building_key: :monument_open, building_status: :empty, construction_status: :new} = tile.(q1)
      assert %{building_key: :hab_open, building_status: :empty, construction_status: :new} = tile.(q2)

      for id <- b["free_tiles"], do: assert(%{building_status: :empty, construction_status: :none} = tile.(id))

      # two real orders, in order, on the queued tiles
      assert [
               %{type: :building, prod_key: :monument_open, tile_id: ^q1, target_id: ^uid},
               %{type: :building, prod_key: :hab_open, tile_id: ^q2, target_id: ^uid}
             ] = Queue.to_list(system.queue.queue)

      # a damaged building gives nothing: the Delta Polytech's technology
      # bonus is absent from the system's breakdown
      refute inspect(system.technology.details) =~ "university_open"

      # the patents were bought, not bypassed, and the player's snapshot
      # of home carries the queue
      {:ok, player} = Game.call(iid, :player, pid, :get_state)
      assert :open_ideo in player.patents and :infra_open_2 in player.patents
      assert b["patents"] != []
      assert Enum.all?(b["patents"], &(String.to_existing_atom(&1) in player.patents))

      # the dev call refuses what would break the tile or the agent
      put = fn tile_id, key, level, status ->
        Game.call(iid, :stellar_system, home, {:dev_put_building, uid, tile_id, key, level, status})
      end

      free = hd(b["free_tiles"])
      assert {:error, :unknown_level} = put.(free, :hab_open, 9, :built)
      assert {:error, :unknown_status} = put.(free, :hab_open, 1, :ruined)
      assert {:error, :unknown_tile} = put.(99, :hab_open, 1, :built)
      assert {:error, :wrong_building_type} = put.(free, :infra_open, 1, :built)
      assert {:error, :wrong_biome} = put.(free, :infra_dome, 1, :built)
      assert {:error, :building_already_under_construction} = put.(q1, :hab_open, 1, :built)

      Application.put_env(:rc, :environment, :prod)
      assert {:error, :not_available} = put.(free, :hab_open, 1, :built)
      Application.put_env(:rc, :environment, :dev)

      {:ok, after_refusals} = Game.call(iid, :stellar_system, home, :get_state)
      assert after_refusals.bodies == system.bodies
    after
      destroy(iid)
    end
  end

  defp post_fixture(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-harness-secret", @secret)
    |> post(@path, Jason.encode!(body))
  end

  defp destroy(iid) do
    Instance.Manager.destroy(iid)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
