defmodule SystemAI.RebelDominionTest do
  @moduledoc """
  The Wave Defense "Rebel Dominion" tree and the actions it adds.

  Drives the REAL parsed tree (`priv/data/system_ai/behavior_tree_wave.json`)
  against real Legacy content with the deterministic fake RNG, the same recipe
  as `SystemAI.UniqueBuildingFilterTest`.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.{ProductionQueue, StellarBody, StellarSystem, Tile}
  alias SystemAI.Helper
  alias Test.FleetScenario

  defmodule BTGalaxy do
    @moduledoc false
    use GenServer

    def init(bt), do: {:ok, bt}
    def handle_call(:get_behavior_tree, _from, bt), do: {:reply, {:ok, bt}, bt}
  end

  setup do
    iid = System.unique_integer([:positive])
    FleetScenario.load_game_data(iid, speed: :slow, mode: :prod)
    {:ok, iid: iid}
  end

  describe "tree data" do
    test "the wave tree parses and the vanilla tree keeps its own behaviour" do
      assert %BehaviorTree.Node{} = SystemAI.Trees.reload(:rebel_dominion)

      # Node titles actually wired into the trees. The raw files also carry the
      # editor's action palette (`custom_nodes`), which lists every action
      # signature whether or not a tree uses it, so text matching would lie.
      wave = node_titles("data/system_ai/behavior_tree_wave.json")
      vanilla = node_titles("data/system_ai/behavior_tree.json")

      assert "SystemAI.Actions.succeed_upgrade?(0.25, 10)" in wave
      refute "SystemAI.Actions.succeed_upgrade?(0.5, 10)" in wave
      assert "SystemAI.Actions.build_housing()" in wave
      refute "SystemAI.Actions.build_workforce()" in wave
      assert "SystemAI.Actions.no_free_tiles?()" in wave

      assert "SystemAI.Actions.succeed_upgrade?(0.5, 10)" in vanilla
      assert "SystemAI.Actions.build_workforce()" in vanilla
      refute Enum.any?(vanilla, &(&1 =~ "upgrade_any" or &1 =~ "build_housing"))
    end
  end

  describe "get_legal_upgrades/1" do
    test "outside orbit, buildings can only rise to their infrastructure's level", %{iid: iid} do
      state =
        system(iid, [
          dome([
            Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
            Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
            Tile.new(3, :primary) |> Tile.force_building(:mine_dome, 1)
          ])
        ])

      assert keys(Helper.get_legal_upgrades(state)) == [:infra_dome]

      raised = put_tile(state, 1, &Tile.force_building(&1, :infra_dome, 2))
      assert keys(Helper.get_legal_upgrades(raised)) == [:hab_dome, :infra_dome, :mine_dome]
    end

    test "orbital buildings have no infrastructure ceiling", %{iid: iid} do
      state = system(iid, [moon([Tile.new(1, :secondary) |> Tile.force_building(:mine_orbital, 2)])])
      assert keys(Helper.get_legal_upgrades(state)) == [:mine_orbital]
    end

    test "excludes max-level buildings and tiles already under construction", %{iid: iid} do
      max = Helper.get_building_max_level(:mine_orbital, iid)

      state =
        system(iid, [
          moon([
            Tile.new(1, :secondary) |> Tile.force_building(:mine_orbital, max),
            %{Tile.force_building(Tile.new(2, :secondary), :factory_orbital, 1) | construction_status: :upgrade}
          ])
        ])

      assert Helper.get_legal_upgrades(state) == []
    end
  end

  describe "the Rebel Dominion tree" do
    test "a workforce-starved system builds housing, where the vanilla tree stalls", %{iid: iid} do
      # infrastructure, housing and a mine in place, free tiles left, and no
      # free workforce: anything but housing (0 workforce) would be skipped
      state =
        %{
          system(iid, [
            dome([
              Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
              Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
              Tile.new(3, :primary) |> Tile.force_building(:mine_dome, 1),
              Tile.new(4, :primary),
              Tile.new(5, :primary)
            ])
          ])
          | workforce: 0
        }

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert {:ok, rebel} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(rebel.queue.queue)
      assert {item.prod_key, item.prod_level, item.tile_id} == {:hab_dome, 1, 4}

      vanilla = Instance.SystemAI.Parser.parse!(Path.join(:code.priv_dir(:rc), "data/system_ai/behavior_tree.json"), "Dominion")
      {:ok, _} = GenServer.start_link(BTGalaxy, vanilla, name: Game.via_tuple({iid, :galaxy, :master}))

      assert {:ok, stalled} = SystemAI.do_action(state, 3)
      assert Queue.to_list(stalled.queue.queue) == []
    end

    test "a built-out system upgrades instead of standing still", %{iid: iid} do
      state =
        system(iid, [
          dome([
            Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
            Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
            Tile.new(3, :primary) |> Tile.force_building(:mine_dome, 1)
          ])
        ])

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert {:ok, new_state} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(new_state.queue.queue)
      assert {item.type, item.prod_key, item.prod_level} == {:building, :infra_dome, 2}
    end

    test "a system with nothing left to build or upgrade ends the turn instead of looping", %{iid: iid} do
      max = Helper.get_building_max_level(:mine_orbital, iid)
      state = system(iid, [moon([Tile.new(1, :secondary) |> Tile.force_building(:mine_orbital, max)])])

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert {:ok, new_state} = SystemAI.do_action(state, 1, :rebel_dominion)
      assert Queue.to_list(new_state.queue.queue) == []
    end
  end

  test "a runaway tree is cut off instead of hanging the agent", %{iid: iid} do
    FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

    # a root whose only child always fails restarts forever without the budget
    tree = BehaviorTree.Node.select([SystemAI.Actions.action(SystemAI.Actions, :succeed_rate, [0.0])])
    context = %{bt: BehaviorTree.start(tree), system_value: 0}

    assert SystemAI.step({context, system(iid, [])}) == {:error, :bt_runaway}
  end

  # --- builders ---------------------------------------------------------------

  # Tuned so every earlier root branch of the tree declines: empty queue, no
  # housing headroom, workforce and happiness comfortably above their triggers.
  defp system(iid, bodies) do
    struct(StellarSystem, %{
      id: 4242,
      name: "rebel-test",
      status: :inhabited_player,
      instance_id: iid,
      bodies: bodies,
      queue: ProductionQueue.new(),
      siege: nil,
      owner: nil,
      workforce: 20,
      used_workforce: 0,
      habitation: %Core.Value{value: 0, details: %{}},
      happiness: %Core.Value{value: 50, details: %{}},
      population: Core.DynamicValue.new(0.0),
      ai_profile: :production
    })
  end

  defp dome(tiles), do: body("1", :sterile_planet, tiles)
  defp moon(tiles), do: body("2", :moon, tiles)

  defp body(uid, type, tiles) do
    struct(StellarBody, %{
      id: String.to_integer(uid),
      uid: uid,
      type: type,
      name: "Body #{uid}",
      industrial_factor: 3,
      technological_factor: 3,
      activity_factor: 3,
      population: 10,
      bodies: [],
      tiles: tiles
    })
  end

  defp put_tile(state, tile_id, fun) do
    [body] = state.bodies
    tiles = Enum.map(body.tiles, fn t -> if t.id == tile_id, do: fun.(t), else: t end)
    %{state | bodies: [%{body | tiles: tiles}]}
  end

  defp keys(tiles), do: tiles |> Enum.map(& &1.building_key) |> Enum.sort()

  defp node_titles(priv_path) do
    :rc
    |> :code.priv_dir()
    |> Path.join(priv_path)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("trees")
    |> Enum.flat_map(fn tree -> Map.values(tree["nodes"]) end)
    |> Enum.map(& &1["title"])
  end
end
