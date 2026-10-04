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
      assert "SystemAI.Actions.improve_happiness()" in wave
      assert "SystemAI.Actions.housing_short?(10)" in wave
      assert "SystemAI.Actions.happiness_needed?(0)" in wave
      refute "SystemAI.Actions.build_happiness()" in wave

      assert "SystemAI.Actions.succeed_upgrade?(0.5, 10)" in vanilla
      assert "SystemAI.Actions.build_workforce()" in vanilla
      refute Enum.any?(vanilla, &(&1 =~ "upgrade_any" or &1 =~ "build_housing"))
      refute Enum.any?(vanilla, &(&1 =~ "improve_happiness" or &1 =~ "housing_short"))
    end

    test "the wave tree draws by suitability; the vanilla tree keeps its even draw" do
      wave = node_titles("data/system_ai/behavior_tree_wave.json")
      vanilla = node_titles("data/system_ai/behavior_tree.json")

      for biome <- [":open", ":dome", ":orbital"] do
        assert "SystemAI.Actions.choose_suited_category(#{biome})" in wave
        assert "SystemAI.Actions.build_suited(#{biome}, 0.75)" in wave
        assert "SystemAI.Actions.choose_category(#{biome})" in vanilla
        assert "SystemAI.Actions.build_random(#{biome})" in vanilla
      end

      assert "SystemAI.Actions.upgrade_suited()" in wave
      assert "SystemAI.Actions.reserved_for_specials?()" in wave
      assert "SystemAI.Actions.build_special()" in wave
      assert "SystemAI.Actions.stability_needed?(10, 25)" in wave
      assert "SystemAI.Actions.staple_wanted?()" in wave
      assert "SystemAI.Actions.build_staple()" in wave

      refute Enum.any?(wave, &(&1 =~ "choose_category(" or &1 =~ "build_random(" or &1 =~ "upgrade_any()"))
      refute Enum.any?(vanilla, &(&1 =~ "suited" or &1 =~ "special" or &1 =~ "facility" or &1 =~ "stability"))
      refute Enum.any?(vanilla, &(&1 =~ "staple"))
      # the academy is a staple now, not a step of its own
      refute Enum.any?(wave, &(&1 =~ "facility"))
    end

    test "happiness is dealt with before workforce, and unrest holds everything after it" do
      tree =
        "data/system_ai/behavior_tree_wave.json"
        |> read_trees()
        |> Enum.find(&(&1["id"] == "rebel-dominion"))

      order = Enum.map(tree["nodes"][tree["root"]]["children"], &tree["nodes"][&1]["title"])
      at = fn title -> Enum.find_index(order, &(&1 == title)) end

      assert at.("Happiness") < at.("Unrest hold")
      assert at.("Unrest hold") < at.("Workforce")
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

      vanilla =
        Instance.SystemAI.Parser.parse!(Path.join(:code.priv_dir(:rc), "data/system_ai/behavior_tree.json"), "Dominion")

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

  # Mons, instance 185: a two-day-old rebel colony at happiness -8 with almost
  # twice the housing it needed, every planet tile spent on it, one free
  # worker, and the tree still asking for housing first.
  describe "an unhappy rebel system" do
    test "raises happiness before anything else, with what its workforce can staff", %{iid: iid} do
      state =
        unhappy(iid, [
          open([
            Tile.new(1, :primary) |> Tile.force_building(:infra_open, 1),
            Tile.new(2, :primary) |> Tile.force_building(:hab_open_poor, 1),
            Tile.new(3, :primary)
          ]),
          moon([Tile.new(1, :secondary)])
        ])

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      # One free worker: the planet's happiness buildings need two or more, the
      # one-worker orbital one fits. No more housing, whatever the workforce says.
      assert Helper.happiness_builds(state) == [{"2", 1, :happy_orbital, 1}]

      assert {:ok, rebel} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(rebel.queue.queue)
      assert {item.prod_key, item.prod_level} == {:happy_orbital, 1}
    end

    test "with no workforce to spare it upgrades a happiness building instead", %{iid: iid} do
      state =
        %{
          unhappy(iid, [
            moon([
              Tile.new(1, :secondary) |> Tile.force_building(:happy_pot_orbital, 1),
              Tile.new(2, :secondary) |> Tile.force_building(:mine_orbital, 1),
              Tile.new(3, :secondary)
            ])
          ])
          | used_workforce: 10
        }

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert Helper.happiness_builds(state) == []
      assert keys(Helper.happiness_upgrades(state)) == [:happy_pot_orbital]

      assert {:ok, rebel} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(rebel.queue.queue)
      assert {item.type, item.prod_key, item.prod_level} == {:building, :happy_pot_orbital, 2}
    end

    test "in unrest with nothing that would help, it builds nothing rather than dig deeper", %{iid: iid} do
      state =
        %{
          unhappy(iid, [
            moon([Tile.new(1, :secondary) |> Tile.force_building(:mine_orbital, 1), Tile.new(2, :secondary)])
          ])
          | used_workforce: 10
        }

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert Helper.happiness_builds(state) == []
      assert Helper.happiness_upgrades(state) == []

      assert {:ok, rebel} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert Queue.to_list(rebel.queue.queue) == []
    end
  end

  describe "housing" do
    test "is only built while it is what holds the population back", %{iid: iid} do
      bodies = [
        dome([
          Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
          Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
          Tile.new(3, :primary) |> Tile.force_building(:mine_dome, 1),
          Tile.new(4, :primary)
        ])
      ]

      starved = %{system(iid, bodies) | workforce: 0}
      short = %{starved | habitation: %Core.Value{value: 12, details: %{}}, population: Core.DynamicValue.new(8.0)}
      roomy = %{starved | habitation: %Core.Value{value: 40, details: %{}}, population: Core.DynamicValue.new(8.0)}

      assert SystemAI.Actions.housing_short?({%{}, short}, 10) == :succeed
      assert SystemAI.Actions.housing_short?({%{}, roomy}, 10) == :fail

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.75, random_index: 0)

      assert {:ok, built} = SystemAI.do_action(short, 3, :rebel_dominion)
      assert [%{prod_key: :hab_dome}] = Queue.to_list(built.queue.queue)

      # Thirty-two free places already: the workforce will come from growth,
      # not from another housing block. With no worker to staff a new
      # building, the turn goes to an upgrade, which needs none.
      assert {:ok, waiting} = SystemAI.do_action(roomy, 3, :rebel_dominion)
      assert [%{prod_key: :infra_dome, prod_level: 2}] = Queue.to_list(waiting.queue.queue)
    end
  end

  describe "system types" do
    test "a new system draws its type with military a little rarer and credit a little commoner" do
      draw = Helper.profile_draw()

      assert length(draw) == 20
      assert Enum.frequencies(draw) == %{production: 4, credit: 5, technologic: 4, ideologic: 4, defense: 3}
      assert Enum.sort(Enum.uniq(draw)) == Enum.sort(Helper.profiles())
    end

    test "a military system leans on production, then defense, then credit, research, ideology" do
      odds = Helper.get_suited_profile_odds(:defense)

      assert_in_delta odds |> Keyword.values() |> Enum.sum(), 1.0, 1.0e-9
      assert odds[:production] > odds[:defense]
      assert odds[:defense] > odds[:credit]
      assert odds[:credit] > odds[:technologic]
      assert odds[:technologic] > odds[:ideologic]

      # production leads clearly: a fleet yard is a production system first
      assert odds[:production] > 1.5 * odds[:defense]

      emphasis = Helper.suited_emphasis(:defense)
      assert emphasis.sys_defense > emphasis.sys_production
      assert emphasis.sys_production == 2.0
      assert Helper.own_targets(:defense) == [:sys_production, :sys_defense]
      assert emphasis.sys_ideology < 1.0 and emphasis.sys_mobility < 1.0

      # every other type keeps the vanilla category odds
      assert Helper.get_suited_profile_odds(:credit) == Helper.get_profile_probabilities(:credit)
    end

    test "stability matters sooner in a military system", %{iid: iid} do
      calm = %{system(iid, []) | happiness: %Core.Value{value: 18, details: %{}}}

      assert SystemAI.Actions.stability_needed?({%{}, calm}, 10, 25) == :fail
      assert SystemAI.Actions.stability_needed?({%{}, %{calm | ai_profile: :defense}}, 10, 25) == :succeed
    end
  end

  describe "the suited draw" do
    test "a weighted draw gives every entry its share, and an even draw when nothing has any", %{iid: iid} do
      rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.0, random_index: 1)
      lots = [a: 1.0, b: 3.0]

      assert Helper.draw_weighted(lots, iid) == {:a, 1.0}
      GenServer.call(rand, {:set, :uniform_value, 0.24})
      assert Helper.draw_weighted(lots, iid) == {:a, 1.0}
      GenServer.call(rand, {:set, :uniform_value, 0.26})
      assert Helper.draw_weighted(lots, iid) == {:b, 3.0}
      GenServer.call(rand, {:set, :uniform_value, 0.99})
      assert Helper.draw_weighted(lots, iid) == {:b, 3.0}

      assert Helper.draw_weighted([a: 0.0, b: 0.0], iid) == {:b, 0.0}
      assert Helper.draw_weighted([], iid) == nil
    end

    test "earlier stages' buildings stay on offer in a developed system", %{iid: iid} do
      asteroid =
        rock("4", %{industrial_factor: 5, technological_factor: 5, activity_factor: 1}, [Tile.new(1, :secondary)])

      bodies = Helper.get_bodies(system(iid, [asteroid]))
      [body] = bodies

      keys = fn tiers ->
        for category <- Helper.profiles(),
            building <- Helper.drawable_buildings(iid, category, :orbital, body, bodies, 20, tiers),
            uniq: true,
            do: building.key
      end

      # Past 18 buildings the vanilla stage offers only what needs 3 to 6
      # workers: in orbit the Business Arch, the radar and the large shipyards.
      assert Enum.sort(keys.(:stage)) ==
               [:finance_orbital, :radar_orbital, :shipyard_2_orbital, :shipyard_3_orbital, :shipyard_4_orbital]

      assert :mine_orbital in keys.(:up_to)
      assert :research_orbital in keys.(:up_to)
      assert :factory_orbital in keys.(:up_to)
      assert Enum.all?(keys.(:stage), &(&1 in keys.(:up_to)))
    end

    test "on a science 5, appeal 1 asteroid nothing that suits it badly is ever built", %{iid: iid} do
      # A poor moon holds the specials; the asteroid is the body under test.
      state =
        system(iid, [
          moon([Tile.new(1, :secondary)]),
          rock("4", %{industrial_factor: 5, technological_factor: 5, activity_factor: 1}, [
            Tile.new(1, :secondary),
            Tile.new(2, :secondary)
          ])
        ])

      assert Helper.reserved_bodies(state) == ["2"]

      # random_index 1: the body draw takes the asteroid
      rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.0, random_index: 1)

      built =
        for step <- 0..39 do
          GenServer.call(rand, {:set, :uniform_value, step / 40})
          {:ok, new_state} = SystemAI.do_action(state, 20, :rebel_dominion)

          case Queue.to_list(new_state.queue.queue) do
            [] -> nil
            [item] -> {item.type, item.prod_key}
          end
        end

      keys = for {:building, key} <- built, uniq: true, do: key

      # Refining Ducts, the mines and the Experiment Station all scale with a 5.
      assert Enum.sort(keys) == [:factory_orbital, :mine_orbital, :research_orbital]
      # The Zero-G Arena (appeal 1), the Business Arch (no mobility) and the
      # flat buildings (a 5 still open) fall under the floor: no build, and
      # with nothing to upgrade the turn simply ends.
      assert nil in built
    end

    test "a draw under the floor goes to an upgrade when there is one", %{iid: iid} do
      # Lots: the mine x0.5 (industry 1) and the shipyard x2 (nothing better
      # to do here). A low roll draws the mine, which the floor refuses. An
      # ideologic system has no stake in either, so the lots are the plain ones.
      poor = %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}

      state =
        %{
          system(iid, [
            rock("4", poor, [
              Tile.new(1, :secondary) |> Tile.force_building(:factory_orbital, 1),
              Tile.new(2, :secondary)
            ])
          ])
          | ai_profile: :ideologic
        }

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.0, random_index: 0)

      context = %{system_value: 3, stellar_body_id: "4", category: :production}
      assert {:done, upgraded} = SystemAI.Actions.build_suited({context, state}, :orbital, 0.75)
      assert [item] = Queue.to_list(upgraded.queue.queue)
      assert {item.prod_key, item.prod_level} == {:factory_orbital, 2}

      # Without a floor the same draw is built.
      assert {:done, built} = SystemAI.Actions.build_suited({context, state}, :orbital)
      assert [item] = Queue.to_list(built.queue.queue)
      assert {item.prod_key, item.prod_level} in [{:factory_orbital, 1}, {:mine_orbital, 1}]
    end

    test "upgrades favour the buildings that suit their body", %{iid: iid} do
      # an ideologic system has no stake in either building
      state =
        %{
          system(iid, [
            rock("4", %{industrial_factor: 5, technological_factor: 1, activity_factor: 1}, [
              Tile.new(1, :secondary) |> Tile.force_building(:research_orbital, 1),
              Tile.new(2, :secondary) |> Tile.force_building(:mine_orbital, 1)
            ])
          ])
          | ai_profile: :ideologic
        }

      rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.1, random_index: 0)

      # lots: the Experiment Station x0.5, the mine x2.5 — the mine holds five sixths
      upgraded = fn roll ->
        GenServer.call(rand, {:set, :uniform_value, roll})
        {:done, new_state} = SystemAI.Actions.upgrade_suited({%{}, state})
        [item] = Queue.to_list(new_state.queue.queue)
        item.prod_key
      end

      assert upgraded.(0.1) == :research_orbital
      assert upgraded.(0.2) == :mine_orbital
      assert upgraded.(0.9) == :mine_orbital
    end
  end

  describe "the reserved moon" do
    test "is the poorest one, and holds the specials only", %{iid: iid} do
      state =
        system(iid, [
          rock("4", %{industrial_factor: 5, technological_factor: 2, activity_factor: 2}, [Tile.new(1, :secondary)]),
          rock("5", %{industrial_factor: 2, technological_factor: 2, activity_factor: 1}, [
            Tile.new(1, :secondary),
            Tile.new(2, :secondary)
          ]),
          rock("6", %{industrial_factor: 2, technological_factor: 2, activity_factor: 2}, [Tile.new(1, :secondary)])
        ])

      assert Enum.sort(Enum.map(Helper.special_buildings(iid), & &1.key)) ==
               [:radar_orbital, :shipyard_1_orbital, :shipyard_2_orbital, :shipyard_3_orbital, :shipyard_4_orbital]

      assert Helper.reserved_bodies(state) == ["5"]
      assert SystemAI.Actions.reserved_for_specials?({%{stellar_body_id: "5"}, state}) == :succeed
      assert SystemAI.Actions.reserved_for_specials?({%{stellar_body_id: "4"}, state}) == :fail

      # A young system can only start the small shipyard.
      assert Enum.map(Helper.buildable_specials(state, 3), & &1.key) == [:shipyard_1_orbital]

      # random_index 1: the body draw takes the reserved moon ("5")
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 1)

      assert {:ok, built} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(built.queue.queue)
      assert {item.prod_key, item.target_id} == {:shipyard_1_orbital, "5"}
    end

    test "with no special to start yet, the turn goes to an upgrade and the moon stays free", %{iid: iid} do
      state =
        %{
          system(iid, [
            moon([Tile.new(1, :secondary)]),
            rock("4", %{industrial_factor: 5, technological_factor: 5, activity_factor: 5}, [
              Tile.new(1, :secondary) |> Tile.force_building(:mine_orbital, 1)
            ])
          ])
          | workforce: 1
        }

      assert Helper.reserved_bodies(state) == ["2"]
      assert Helper.buildable_specials(state, 3) == []

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 0)

      assert {:ok, new_state} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [item] = Queue.to_list(new_state.queue.queue)
      assert {item.prod_key, item.prod_level} == {:mine_orbital, 2}
    end

    test "a credit, technology or ideology system keeps none", %{iid: iid} do
      state =
        system(iid, [
          rock("4", %{industrial_factor: 5, technological_factor: 2, activity_factor: 2}, [Tile.new(1, :secondary)]),
          rock("5", %{industrial_factor: 2, technological_factor: 2, activity_factor: 1}, [Tile.new(1, :secondary)])
        ])

      assert Helper.reserved_bodies(state) == ["5"]

      for type <- [:credit, :technologic, :ideologic] do
        assert Helper.reserved_bodies(%{state | ai_profile: type}) == []
        assert SystemAI.Actions.reserved_for_specials?({%{stellar_body_id: "5"}, %{state | ai_profile: type}}) == :fail
      end
    end

    test "a military system keeps enough poor moons for every special", %{iid: iid} do
      bodies = [
        rock("4", %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}, [Tile.new(1, :secondary)]),
        rock("5", %{industrial_factor: 2, technological_factor: 2, activity_factor: 2}, [
          Tile.new(1, :secondary),
          Tile.new(2, :secondary),
          Tile.new(3, :secondary)
        ]),
        rock("6", %{industrial_factor: 3, technological_factor: 2, activity_factor: 2}, [
          Tile.new(1, :secondary),
          Tile.new(2, :secondary)
        ]),
        rock("7", %{industrial_factor: 5, technological_factor: 5, activity_factor: 5}, [Tile.new(1, :secondary)])
      ]

      assert Helper.reserved_bodies(system(iid, bodies)) == ["4"]
      # five specials: one tile, then three, then the two that complete the set
      assert Helper.reserved_bodies(%{system(iid, bodies) | ai_profile: :defense}) == ["4", "5", "6"]
    end

    test "nothing is kept once every special stands", %{iid: iid} do
      specials = [:shipyard_1_orbital, :shipyard_2_orbital, :shipyard_3_orbital, :shipyard_4_orbital, :radar_orbital]

      tiles =
        specials
        |> Enum.with_index(1)
        |> Enum.map(fn {key, id} -> Tile.new(id, :secondary) |> Tile.force_building(key, 1) end)

      state =
        system(iid, [
          rock("4", %{industrial_factor: 5, technological_factor: 5, activity_factor: 5}, tiles),
          moon([Tile.new(1, :secondary)])
        ])

      assert Helper.missing_specials(state) == []
      assert Helper.reserved_bodies(state) == []
    end
  end

  describe "a military system's academy" do
    defp garrison(iid, extra \\ []) do
      %{
        system(iid, [
          dome([
            Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
            Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
            Tile.new(3, :primary)
          ])
          | extra
        ])
        | ai_profile: :defense
      }
    end

    defp staple_key(state, value) do
      case Helper.next_staple(state, value) do
        nil -> nil
        staple -> staple.building.key
      end
    end

    test "is the first staple of the type, once it is on offer and can be staffed", %{iid: iid} do
      state = garrison(iid)
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      assert Helper.staples(:defense, :dome) == [:military_school_dome, :high_factory_dome, :research_dome]
      assert staple_key(state, 8) == :military_school_dome
      # not on offer in a system under 8 buildings, nor with two workers: the
      # common base comes instead
      assert staple_key(state, 3) == :research_dome
      assert staple_key(%{state | workforce: 2}, 8) == :research_dome
      # no other type builds one
      refute :military_school_dome in Helper.staples(:production, :dome)
      assert staple_key(%{state | ai_profile: :credit}, 8) != :military_school_dome
    end

    test "goes on the planet where it displaces the least, and only once", %{iid: iid} do
      tiles = fn ->
        [
          Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
          Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1),
          Tile.new(3, :primary)
        ]
      end

      rich = struct(body("5", :sterile_planet, tiles.()), %{industrial_factor: 5, technological_factor: 5})
      poor = struct(body("6", :sterile_planet, tiles.()), %{industrial_factor: 1, technological_factor: 1})
      state = %{system(iid, [rich, poor]) | ai_profile: :defense}
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      assert %{building: %{key: :military_school_dome}, body_id: "6"} = Helper.next_staple(state, 8)

      trained = %{
        state
        | bodies: [
            rich,
            %{
              poor
              | tiles:
                  List.replace_at(poor.tiles, 2, Tile.force_building(Tile.new(3, :primary), :military_school_dome, 1))
            }
          ]
      }

      # the other sterile planet does not get a second one
      assert staple_key(trained, 8) == :research_dome
    end

    test "the tree builds it before anything else", %{iid: iid} do
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 0)

      assert {:ok, built} = SystemAI.do_action(garrison(iid), 8, :rebel_dominion)
      assert [item] = Queue.to_list(built.queue.queue)
      assert item.prod_key == :military_school_dome
    end
  end

  describe "what each type leans on" do
    # A habitable planet with its infrastructure up and three tiles free: too
    # small for the starter, so the tree goes straight to the planet's own turn.
    defp homeworld(extra \\ []) do
      open([Tile.new(1, :primary) |> Tile.force_building(:infra_open, 1)] ++ extra ++ free_tiles(length(extra) + 2, 3))
    end

    defp colony_dome(extra \\ []) do
      dome(
        [
          Tile.new(1, :primary) |> Tile.force_building(:infra_dome, 1),
          Tile.new(2, :primary) |> Tile.force_building(:hab_dome, 1)
        ] ++ extra ++ free_tiles(length(extra) + 3, 2)
      )
    end

    defp free_tiles(from, count), do: Enum.map(from..(from + count - 1), &Tile.new(&1, :primary))

    defp of_type(state, type), do: %{state | ai_profile: type}

    test "its own resource counts for more, bonus by bonus", %{iid: iid} do
      assert Helper.suited_emphasis(:production) == %{sys_production: 2.0}
      assert Helper.suited_emphasis(:credit) == %{sys_credit: 3.0, sys_mobility: 3.0}
      assert Helper.suited_emphasis(:technologic) == %{sys_technology: 3.0}
      assert Helper.suited_emphasis(:ideologic) == %{sys_ideology: 3.0}

      # An Experiment Station on a science 1 asteroid: x0.5, under the floor
      # anywhere but in a technology system, where it is x1.5.
      state =
        system(iid, [
          rock("4", %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}, [Tile.new(1, :secondary)])
        ])

      bodies = Helper.get_bodies(state)
      [body] = bodies
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      draw = &Helper.get_suited_building(of_type(state, &1), :technologic, :orbital, body, bodies, 3)

      assert {%{key: :research_orbital}, 0.5} = draw.(:credit)
      assert {%{key: :research_orbital}, 1.5} = draw.(:technologic)
    end

    test "its staples are its own, then the base every system carries" do
      # the base: Citadel, Floating Gardens, Delta Polytech; Impact Research Center
      assert Helper.staples(:production, :open) == [:ideo_open, :monument_open, :university_open]
      assert Helper.staples(:production, :dome) == [:high_factory_dome, :research_dome]

      assert Helper.staples(:technologic, :open) == [:university_open, :research_open, :ideo_open, :monument_open]
      assert Helper.staples(:technologic, :dome) == [:research_dome, :high_factory_dome]
      assert Helper.staples(:ideologic, :open) == [:ideo_open, :monument_open, :ideo_credit_open, :university_open]
      assert Helper.staples(:ideologic, :dome) == [:ideo_dome, :monument_dome, :research_dome]

      assert Helper.staples(:credit, :open) ==
               [:hab_open_rich, :market_open, :ideo_open, :monument_open, :university_open]

      assert Helper.staples(:credit, :dome) == [:market_dome, :spatioport_dome, :research_dome]
      assert Helper.staples(:credit, :orbital) == [:spatioport_orbital, :finance_orbital]
      assert Helper.staples(:defense, :open) == [:ideo_open, :monument_open, :university_open]

      for type <- [:production, :technologic, :ideologic, :defense] do
        assert Helper.staples(type, :orbital) == []
      end
    end

    test "the base is built where it pays, in a system of any type", %{iid: iid} do
      # The Citadel and the Polytech are flat and paid by population; the
      # Floating Gardens are flat. On a planet of ten the Gardens come
      # first; with twenty people the Citadel pays and leads.
      state = system(iid, [homeworld()])
      staple = fn state -> Helper.staple_for(state, hd(Helper.get_bodies(state)), 3).building.key end
      crowded = fn state -> %{state | bodies: Enum.map(state.bodies, &%{&1 | population: 20})} end

      # production has no staple of its own on a habitable planet
      assert staple.(of_type(state, :production)) == :monument_open
      assert staple.(crowded.(of_type(state, :production))) == :ideo_open

      # a type's own staples lead, the base follows
      assert staple.(of_type(state, :technologic)) == :university_open
      assert staple.(of_type(state, :credit)) == :hab_open_rich
      with_homes = put_first_body_tile(of_type(state, :credit), 2, &Tile.force_building(&1, :hab_open_rich, 1))
      assert staple.(with_homes) == :monument_open
      assert staple.(crowded.(with_homes)) == :market_open

      # a fleet yard has little use for ideology: Gardens, then the Polytech
      assert staple.(of_type(state, :defense)) == :monument_open
      refute staple.(crowded.(of_type(state, :defense))) == :ideo_open
    end

    test "a staple is the first one the body lacks and the system can start", %{iid: iid} do
      state = iid |> system([homeworld()]) |> of_type(:ideologic)
      [planet] = Helper.get_bodies(state)

      key = fn state, value ->
        case Helper.staple_for(state, hd(Helper.get_bodies(state)), value) do
          nil -> nil
          staple -> staple.building.key
        end
      end

      assert key.(state, 3) == :ideo_open

      with_citadel = put_first_body_tile(state, 2, &Tile.force_building(&1, :ideo_open, 1))
      assert key.(with_citadel, 3) == :monument_open

      # The Network of Artificial Islands needs four workers: not on offer
      # before the system has eight buildings.
      with_gardens = put_first_body_tile(with_citadel, 3, &Tile.force_building(&1, :monument_open, 1))
      assert key.(with_gardens, 3) == nil
      assert key.(with_gardens, 8) == :ideo_credit_open

      # no worker to staff it, or no infrastructure to stand on
      assert Helper.staple_for(%{state | workforce: 1}, planet, 3) == nil
      assert Helper.staple_for(%{state | bodies: [open(free_tiles(1, 3))]}, open(free_tiles(1, 3)), 3) == nil
    end

    test "a wonder waits for the last stage, and stays one per system", %{iid: iid} do
      research = [Tile.new(3, :primary) |> Tile.force_building(:research_dome, 1)]
      lab = iid |> system([colony_dome(research)]) |> of_type(:technologic)
      [planet] = Helper.get_bodies(lab)

      assert Helper.staple_for(lab, planet, 17) == nil
      assert %{building: %{key: :high_factory_dome}, replaces: nil} = Helper.staple_for(lab, planet, 18)

      holodome = [Tile.new(3, :primary) |> Tile.force_building(:ideo_dome, 1)]
      shrine = iid |> system([colony_dome(holodome)]) |> of_type(:ideologic)
      [planet] = Helper.get_bodies(shrine)

      # three workers would do at eight buildings, were it not a wonder: the
      # common base comes instead
      assert %{building: %{key: :research_dome}} = Helper.staple_for(shrine, planet, 8)
      assert %{building: %{key: :monument_dome}} = Helper.staple_for(shrine, planet, 18)

      elsewhere = body("5", :sterile_planet, [Tile.new(1, :primary) |> Tile.force_building(:monument_dome, 1)])

      refute match?(
               %{building: %{key: :monument_dome}},
               Helper.staple_for(%{shrine | bodies: shrine.bodies ++ [elsewhere]}, planet, 18)
             )
    end

    test "the tree builds a staple before the ordinary draw", %{iid: iid} do
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 0)

      shrine = iid |> system([homeworld()]) |> of_type(:ideologic)
      assert {:ok, built} = SystemAI.do_action(shrine, 3, :rebel_dominion)
      assert [%{prod_key: :ideo_open, target_id: "3"}] = Queue.to_list(built.queue.queue)

      lab = iid |> system([colony_dome()]) |> of_type(:technologic)
      assert {:ok, built} = SystemAI.do_action(lab, 3, :rebel_dominion)
      assert [%{prod_key: :research_dome, target_id: "1"}] = Queue.to_list(built.queue.queue)

      # a production system has the common base only
      assert {:succeed, %{staple: %{key: :research_dome}}} =
               SystemAI.Actions.staple_wanted?({%{system_value: 3}, of_type(lab, :production)})
    end

    test "upgrades go to its own resource first", %{iid: iid} do
      # Industry 5, science 1. By suitability alone the mine holds five
      # sixths of the lots (see "upgrades favour the buildings that suit
      # their body"). In a technology system the Experiment Station counts
      # x3 as a bonus and x3 again as the system's own: x4.5 against x2.5.
      state =
        iid
        |> system([
          rock("4", %{industrial_factor: 5, technological_factor: 1, activity_factor: 1}, [
            Tile.new(1, :secondary) |> Tile.force_building(:research_orbital, 1),
            Tile.new(2, :secondary) |> Tile.force_building(:mine_orbital, 1)
          ])
        ])
        |> of_type(:technologic)

      assert Helper.own_upgrades(state, Helper.get_legal_upgrades(state)) == MapSet.new([{"4", 1}])

      rand = FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.1, random_index: 0)

      upgraded = fn roll ->
        GenServer.call(rand, {:set, :uniform_value, roll})
        {:done, new_state} = SystemAI.Actions.upgrade_suited({%{}, state})
        [item] = Queue.to_list(new_state.queue.queue)
        item.prod_key
      end

      assert upgraded.(0.1) == :research_orbital
      assert upgraded.(0.6) == :research_orbital
      assert upgraded.(0.7) == :mine_orbital
    end

    test "the infrastructure that holds its buildings back counts as its own", %{iid: iid} do
      # A Delta Polytech at the level of its Megapolis cannot rise until the Megapolis does.
      polytech = [Tile.new(2, :primary) |> Tile.force_building(:university_open, 1)]
      state = iid |> system([homeworld(polytech)]) |> of_type(:technologic)

      assert [%{id: 1, building_key: :infra_open}] = Helper.get_legal_upgrades(state)
      assert Helper.own_upgrades(state, Helper.get_legal_upgrades(state)) == MapSet.new([{"3", 1}])

      # The Polytech is part of the base every type keeps up; a Commercial
      # Artery is nothing to a production system.
      idle = of_type(state, :production)
      assert Helper.own_upgrades(idle, Helper.get_legal_upgrades(idle)) == MapSet.new([{"3", 1}])

      artery = [Tile.new(2, :primary) |> Tile.force_building(:market_open, 1)]
      idle = iid |> system([homeworld(artery)]) |> of_type(:production)
      assert Helper.own_upgrades(idle, Helper.get_legal_upgrades(idle)) == MapSet.new()

      # with the Megapolis a level ahead, the Polytech itself is the upgrade
      raised = put_first_body_tile(state, 1, &Tile.force_building(&1, :infra_open, 2))
      assert Helper.own_upgrades(raised, Helper.get_legal_upgrades(raised)) == MapSet.new([{"3", 2}])
    end

    test "an ideologic system counts its housing as its own, since ideology follows population", %{iid: iid} do
      housing = [Tile.new(2, :primary) |> Tile.force_building(:hab_open_poor, 1)]
      raised = &put_first_body_tile(&1, 1, fn tile -> Tile.force_building(tile, :infra_open, 2) end)

      shrine = iid |> system([homeworld(housing)]) |> of_type(:ideologic) |> raised.()
      assert {"3", 2} in Helper.own_upgrades(shrine, Helper.get_legal_upgrades(shrine))

      lab = of_type(shrine, :technologic)
      assert Helper.own_upgrades(lab, Helper.get_legal_upgrades(lab)) == MapSet.new()
    end

    test "credit systems house their people in Residential Archipelagos, ideologic ones in Hive Cities", %{iid: iid} do
      state = system(iid, [homeworld()])
      [planet] = Helper.get_bodies(state)
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      assert Helper.housing_key(of_type(state, :credit), planet) == :hab_open_rich
      assert Helper.housing_key(of_type(state, :ideologic), planet) == :hab_open_poor
      # the others: Archipelagos where the planet has appeal (3 here), since
      # they pay credit by it; any housing of the biome where it has none
      assert Helper.housing_key(of_type(state, :technologic), planet) == :hab_open_rich
      assert Helper.housing_key(of_type(state, :credit), %{planet | activity_factor: 1}) == :hab_open_rich

      assert Helper.housing_key(of_type(state, :technologic), %{planet | activity_factor: 2}) in [
               :hab_open,
               :hab_open_poor,
               :hab_open_rich
             ]

      # sterile planets have one kind of housing
      assert Helper.housing_key(of_type(state, :credit), dome([])) == :hab_dome

      assert {:done, built} = SystemAI.Actions.build_housing({%{}, of_type(state, :credit)})
      assert [%{prod_key: :hab_open_rich}] = Queue.to_list(built.queue.queue)
    end

    test "a type may upgrade the wonder it builds as a staple; no other type may", %{iid: iid} do
      factory = [Tile.new(3, :primary) |> Tile.force_building(:high_factory_dome, 1)]
      state = system(iid, [colony_dome(factory)]) |> put_first_body_tile(1, &Tile.force_building(&1, :infra_dome, 2))

      upgradable = fn type -> state |> of_type(type) |> Helper.get_legal_upgrades() |> Enum.map(& &1.building_key) end

      # technology runs on it, and so do the two types that build the fleets
      for type <- [:technologic, :production, :defense], do: assert(:high_factory_dome in upgradable.(type))
      for type <- [:credit, :ideologic], do: refute(:high_factory_dome in upgradable.(type))
    end
  end

  describe "what the Rebellion holds the patent for" do
    # A system the Rebellion holds, in a wave game whose Warlord has published
    # these patents and this stage of the game.
    defp rebel(state, patents, stage \\ :early) do
      Data.Data.update_metadata(state.instance_id, :wave, true)
      Data.Data.update_metadata(state.instance_id, :wave_config, %{"bot_faction" => "rebellion"})
      Wave.Config.publish_economy(state.instance_id, patents, stage)
      %{state | owner: %{id: 1, faction: :rebellion}}
    end

    defp catalog(iid, key), do: Enum.find(SystemAI.BuildingsHelper.get_all_buildings(iid), &(&1.key == key))

    test "binds a rebel system once it is published, and no other system", %{iid: iid} do
      state = system(iid, [])
      mine = catalog(iid, :mine_orbital)

      # nothing published: ungated, as outside a wave game
      assert Helper.patented?(state, mine)
      assert Helper.patented?(%{state | owner: %{id: 1, faction: :rebellion}}, mine)

      held = rebel(state, [:orbital_credit])
      refute Helper.patented?(held, mine)
      assert Helper.patented?(held, catalog(iid, :factory_orbital))
      # Residential Districts and the Delta Polytech need no patent
      assert Helper.patented?(held, catalog(iid, :hab_open))
      assert Helper.patented?(held, catalog(iid, :university_open))
      # a neutral system or a human's dominion in the same game is not held to it
      assert Helper.patented?(%{held | owner: nil}, mine)
      assert Helper.patented?(%{held | owner: %{id: 2, faction: :myrmezir}}, mine)

      assert Helper.patented?(rebel(state, [:orbital_credit, :orbital_prod]), mine)
    end

    test "decides what a moon is offered", %{iid: iid} do
      asteroid =
        rock("4", %{industrial_factor: 5, technological_factor: 5, activity_factor: 1}, [Tile.new(1, :secondary)])

      offered = fn state ->
        bodies = Helper.get_bodies(state)

        for category <- Helper.profiles(),
            {_category, odds} <- [
              List.keyfind(Helper.get_suited_category_odds(state, hd(bodies), bodies, :orbital, 3), category, 0)
            ],
            odds > 0,
            do: category
      end

      early = rebel(system(iid, [asteroid]), [:orbital_credit])
      # Refining Ducts only: they count as production and as credit
      assert offered.(early) == [:production, :credit]

      later = rebel(system(iid, [asteroid]), [:orbital_credit, :orbital_research, :orbital_defense])
      assert offered.(later) == [:production, :credit, :technologic, :defense]
    end

    test "a level needs its own patent", %{iid: iid} do
      state =
        system(iid, [
          rock("4", %{industrial_factor: 5, technological_factor: 1, activity_factor: 1}, [
            Tile.new(1, :secondary) |> Tile.force_building(:factory_orbital, 1)
          ]),
          homeworld()
        ])

      upgradable = fn patents ->
        state |> rebel(patents) |> Helper.get_legal_upgrades() |> Enum.map(& &1.building_key)
      end

      assert upgradable.([:orbital_credit, :infra_open_1]) == []
      assert upgradable.([:orbital_credit, :infra_open_1, :infra_orbital_2]) == [:factory_orbital]

      assert Enum.sort(upgradable.([:orbital_credit, :infra_open_1, :infra_orbital_2, :infra_open_2])) ==
               [:factory_orbital, :infra_open]
    end

    test "a staple waits for its patent", %{iid: iid} do
      state = iid |> system([homeworld()]) |> of_type(:ideologic)
      [planet] = Helper.get_bodies(state)
      staple = fn patents -> state |> rebel(patents) |> Helper.staple_for(planet, 3) end

      assert staple.([:infra_open_1]) == nil
      assert %{building: %{key: :ideo_open}} = staple.([:infra_open_1, :citadel])
      # the Citadel's patent missing, the Floating Gardens' held: the next staple down the list
      assert %{building: %{key: :monument_open}} = staple.([:infra_open_1, :open_ideo])
    end

    test "a wonder waits for the late game, patent or not", %{iid: iid} do
      research = [Tile.new(3, :primary) |> Tile.force_building(:research_dome, 1)]
      lab = iid |> system([colony_dome(research)]) |> of_type(:technologic)
      [planet] = Helper.get_bodies(lab)
      patents = [:infra_dome_1, :dome_industries]

      assert Helper.staple_for(rebel(lab, patents, :mid), planet, 18) == nil
      assert %{building: %{key: :high_factory_dome}} = Helper.staple_for(rebel(lab, patents, :late), planet, 18)
      assert Helper.staple_for(rebel(lab, [:infra_dome_1], :late), planet, 18) == nil
    end

    test "the tree skips a building the Rebellion cannot build yet", %{iid: iid} do
      state = iid |> system([homeworld()]) |> rebel([:infra_open_1])
      context = %{system_value: 3, stellar_body_id: "3"}
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      # Hive Cities need Cookie-cutter Cities; a Delta Polytech needs nothing
      assert SystemAI.Actions.build({context, state}, :hab_open_poor) == :fail
      assert {:done, built} = SystemAI.Actions.build({context, state}, :university_open)
      assert [%{prod_key: :university_open}] = Queue.to_list(built.queue.queue)
    end

    test "housing is the type's choice once patented, and something else until then", %{iid: iid} do
      state = iid |> system([homeworld()]) |> of_type(:credit)
      [planet] = Helper.get_bodies(state)
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.5, random_index: 0)

      assert Helper.housing_options(rebel(state, [:infra_open_1]), :open) == [:hab_open]
      assert Helper.housing_key(rebel(state, [:infra_open_1]), planet) == :hab_open
      assert Helper.housing_key(rebel(state, [:infra_open_1, :open_credit]), planet) == :hab_open_rich

      # a sterile planet has Capsule Cities or nothing
      assert Helper.housing_options(rebel(state, [:infra_dome_1]), :dome) == []
      assert Helper.housing_key(rebel(state, [:infra_dome_1]), dome([])) == nil
      assert Helper.housing_options(rebel(state, [:infra_dome_1, :dome_pop]), :dome) == [:hab_dome]
    end
  end

  describe "a staple on a full body" do
    defp full_planet(tiles) do
      open([Tile.new(1, :primary) |> Tile.force_building(:infra_open, 1)] ++ tiles)
    end

    defp standing(id, key), do: Tile.new(id, :primary) |> Tile.force_building(key, 1)

    test "takes the tile of the building that suits the system least", %{iid: iid} do
      # Industry 3: an Industrial Hub is x1.5 here and a Planetary Shield x1.
      # The Citadel, flat and paid by population, is x1.8 in an ideologic
      # system: it takes the shield's tile.
      planet = full_planet([standing(2, :hab_open), standing(3, :factory_open), standing(4, :defense_local_open)])
      state = iid |> system([planet]) |> of_type(:ideologic)
      [body] = Helper.get_bodies(state)

      assert %{building: %{key: :ideo_open}, tile_id: 4, replaces: :defense_local_open} =
               Helper.staple_for(state, body, 3)

      # with a free tile it displaces nothing
      roomy = %{state | bodies: [full_planet([standing(2, :factory_open), Tile.new(3, :primary)])]}
      assert %{tile_id: 3, replaces: nil} = Helper.staple_for(roomy, hd(Helper.get_bodies(roomy)), 3)
    end

    test "the base takes the tile of a building the type has no stake in, and never one it has", %{iid: iid} do
      # A production system: the Commercial Artery pays credit, which it does
      # not count for more; the Industrial Hubs pay production, which it does.
      crowded = fn planet -> %{planet | population: 20} end
      mixed = full_planet([standing(2, :hab_open), standing(3, :factory_open), standing(4, :market_open)])
      state = system(iid, [crowded.(mixed)])
      staple = fn state -> Helper.staple_for(state, hd(Helper.get_bodies(state)), 3) end

      # the Citadel suits the planet less than the Artery does (x1.15 to x1.3): the base takes its tile anyway
      assert %{building: %{key: :ideo_open}, tile_id: 4, replaces: :market_open} = staple.(state)

      hubs = full_planet([standing(2, :hab_open), standing(3, :factory_open), standing(4, :factory_open)])
      assert staple.(%{state | bodies: [crowded.(hubs)]}) == nil

      # in a credit system the Artery and the Hub both pay credit: nothing to take
      assert staple.(of_type(state, :credit)) == nil
    end

    test "never takes infrastructure, housing, a happiness building or another staple", %{iid: iid} do
      # housing, the Citadel's fellow staple and a happiness building: nothing to displace
      planet = full_planet([standing(2, :hab_open), standing(3, :monument_open), standing(4, :happy_pot_open)])
      state = iid |> system([planet]) |> of_type(:ideologic)

      assert Helper.staple_for(state, hd(Helper.get_bodies(state)), 3) == nil
    end

    test "leaves a building that suits the system better", %{iid: iid} do
      # Refining Ducts on industry 5 are x5 in a credit system; the Terminus is x3
      rich = %{industrial_factor: 5, technological_factor: 1, activity_factor: 1}
      poor = %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}

      ducts = fn potentials ->
        rock("4", potentials, [Tile.new(1, :secondary) |> Tile.force_building(:factory_orbital, 1)])
      end

      staple = fn potentials ->
        state = iid |> system([ducts.(potentials)]) |> of_type(:credit)
        Helper.staple_for(state, hd(Helper.get_bodies(state)), 8)
      end

      assert staple.(rich) == nil
      assert %{building: %{key: :spatioport_orbital}, replaces: :factory_orbital} = staple.(poor)
    end

    test "the old building comes down and the new one starts in the same turn", %{iid: iid} do
      planet = full_planet([standing(2, :hab_open), standing(3, :factory_open), standing(4, :factory_open)])

      # Taking a building down recomputes the system's bonuses, which reads
      # fields the other tests can leave unset.
      state =
        %{
          (iid
           |> system([planet])
           |> of_type(:ideologic))
          | remove_contact: Core.DynamicValue.new(0.0),
            happiness_penalties: [],
            capital?: false
        }

      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 0)

      assert {:ok, turned} = SystemAI.do_action(state, 3, :rebel_dominion)
      assert [%{prod_key: :ideo_open, target_id: "3", tile_id: 3}] = Queue.to_list(turned.queue.queue)
      [body] = turned.bodies
      tile = Enum.find(body.tiles, &(&1.id == 3))
      assert {tile.building_key, tile.building_status, tile.construction_status} == {:ideo_open, :empty, :new}

      # short of workers for the new building, the old one stays
      starved = %{state | workforce: 1, used_workforce: 0}

      context = %{
        system_value: 3,
        stellar_body_id: "3",
        staple: %{key: :ideo_open, tile_id: 3, replaces: :factory_open}
      }

      assert SystemAI.Actions.build_staple({context, starved}) == :fail
    end
  end

  describe "what costs happiness" do
    test "a Business Arch waits for mobility to pay and for happiness to spare", %{iid: iid} do
      moon = rock("4", %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}, [Tile.new(1, :secondary)])
      terminus = [Tile.new(1, :secondary) |> Tile.force_building(:spatioport_orbital, 1), Tile.new(2, :secondary)]
      state = iid |> system([%{moon | tiles: terminus}]) |> of_type(:credit)
      staple = fn state -> Helper.staple_for(state, hd(Helper.get_bodies(state)), 8) end
      mobile = fn state, value -> %{state | mobility: %Core.Value{value: value, details: %{}}} end

      # x0.6 at a mobility of 20, x3 at 40
      assert staple.(mobile.(state, 20.0)) == nil
      assert %{building: %{key: :finance_orbital}} = staple.(mobile.(state, 40.0))

      # it costs 3.6 happiness: not below the reserve of 20
      tense = %{mobile.(state, 40.0) | happiness: %Core.Value{value: 23.0, details: %{}}}
      assert staple.(tense) == nil
    end

    test "is counted level by level", %{iid: iid} do
      arch = Enum.find(SystemAI.BuildingsHelper.get_all_buildings(iid), &(&1.key == :finance_orbital))
      mine = Enum.find(SystemAI.BuildingsHelper.get_all_buildings(iid), &(&1.key == :mine_orbital))

      assert_in_delta Helper.happiness_cost(arch, 1), 3.6, 1.0e-9
      assert Helper.happiness_cost(arch, 2) > 0
      assert Helper.happiness_cost(mine, 1) == 0.0

      state = %{system(iid, []) | happiness: %Core.Value{value: 22.0, details: %{}}}
      refute Helper.affordable?(state, arch)
      assert Helper.affordable?(state, mine)
      assert Helper.affordable?(%{state | happiness: %Core.Value{value: 60.0, details: %{}}}, arch)
    end

    test "an upgrade the system cannot afford is not drawn", %{iid: iid} do
      state =
        %{
          system(iid, [
            rock("4", %{industrial_factor: 3, technological_factor: 1, activity_factor: 1}, [
              Tile.new(1, :secondary) |> Tile.force_building(:finance_orbital, 1),
              Tile.new(2, :secondary) |> Tile.force_building(:mine_orbital, 1)
            ])
          ])
          | happiness: %Core.Value{value: 21.0, details: %{}}
        }

      legal = Helper.get_legal_upgrades(state)
      assert Enum.sort(Enum.map(legal, & &1.building_key)) == [:finance_orbital, :mine_orbital]
      assert Enum.map(Helper.affordable_upgrades(state, legal), & &1.building_key) == [:mine_orbital]
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

  # In unrest, housing to spare, and one free worker: workforce "needed" by the
  # tree's own rule, yet more housing is the last thing it wants.
  defp unhappy(iid, bodies) do
    %{
      system(iid, bodies)
      | workforce: 10,
        used_workforce: 9,
        happiness: %Core.Value{value: -5, details: %{}},
        habitation: %Core.Value{value: 40, details: %{}},
        population: Core.DynamicValue.new(10.0)
    }
  end

  defp dome(tiles), do: body("1", :sterile_planet, tiles)
  defp moon(tiles), do: body("2", :moon, tiles)
  defp open(tiles), do: body("3", :habitable_planet, tiles)

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

  # An asteroid with the given potentials.
  defp rock(uid, potentials, tiles), do: struct(body(uid, :asteroid, tiles), potentials)

  defp put_first_body_tile(state, tile_id, fun) do
    [body | rest] = state.bodies
    tiles = Enum.map(body.tiles, fn t -> if t.id == tile_id, do: fun.(t), else: t end)
    %{state | bodies: [%{body | tiles: tiles} | rest]}
  end

  defp put_tile(state, tile_id, fun) do
    [body] = state.bodies
    tiles = Enum.map(body.tiles, fn t -> if t.id == tile_id, do: fun.(t), else: t end)
    %{state | bodies: [%{body | tiles: tiles}]}
  end

  defp keys(tiles), do: tiles |> Enum.map(& &1.building_key) |> Enum.sort()

  defp node_titles(priv_path) do
    priv_path
    |> read_trees()
    |> Enum.flat_map(fn tree -> Map.values(tree["nodes"]) end)
    |> Enum.map(& &1["title"])
  end

  defp read_trees(priv_path) do
    :rc
    |> :code.priv_dir()
    |> Path.join(priv_path)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("trees")
  end
end
