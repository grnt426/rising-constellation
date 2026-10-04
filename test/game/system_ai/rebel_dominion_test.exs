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
      assert "SystemAI.Actions.facility_wanted?(:military_school_dome)" in wave
      assert "SystemAI.Actions.stability_needed?(10, 25)" in wave

      refute Enum.any?(wave, &(&1 =~ "choose_category(" or &1 =~ "build_random(" or &1 =~ "upgrade_any()"))
      refute Enum.any?(vanilla, &(&1 =~ "suited" or &1 =~ "special" or &1 =~ "facility" or &1 =~ "stability"))
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

      emphasis = Helper.suited_emphasis(:defense)
      assert emphasis.sys_defense > emphasis.sys_production
      assert emphasis.sys_production > 1.0
      assert emphasis.sys_ideology < 1.0 and emphasis.sys_mobility < 1.0

      # every other type keeps the vanilla odds and no emphasis
      assert Helper.get_suited_profile_odds(:credit) == Helper.get_profile_probabilities(:credit)
      assert Helper.suited_emphasis(:credit) == %{}
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
      # to do here). A low roll draws the mine, which the floor refuses.
      poor = %{industrial_factor: 1, technological_factor: 1, activity_factor: 1}

      state =
        system(iid, [
          rock("4", poor, [Tile.new(1, :secondary) |> Tile.force_building(:factory_orbital, 1), Tile.new(2, :secondary)])
        ])

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
      state =
        system(iid, [
          rock("4", %{industrial_factor: 5, technological_factor: 1, activity_factor: 1}, [
            Tile.new(1, :secondary) |> Tile.force_building(:research_orbital, 1),
            Tile.new(2, :secondary) |> Tile.force_building(:mine_orbital, 1)
          ])
        ])

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

    test "is wanted on the planet where it displaces the least, once it is on offer", %{iid: iid} do
      state = garrison(iid)
      context = %{system_value: 8, stellar_body_id: "1"}

      assert SystemAI.Actions.facility_wanted?({context, state}, :military_school_dome) == :succeed
      # not on offer yet in a system under 8 buildings
      assert SystemAI.Actions.facility_wanted?({%{context | system_value: 3}, state}, :military_school_dome) == :fail
      # no workforce for it
      assert SystemAI.Actions.facility_wanted?({context, %{state | workforce: 2}}, :military_school_dome) == :fail
      # only a military system goes out of its way
      assert SystemAI.Actions.facility_wanted?({context, %{state | ai_profile: :credit}}, :military_school_dome) ==
               :fail
    end

    test "is not wanted twice", %{iid: iid} do
      state = garrison(iid) |> put_first_body_tile(3, &Tile.force_building(&1, :military_school_dome, 1))

      assert SystemAI.Actions.facility_wanted?({%{system_value: 8, stellar_body_id: "1"}, state}, :military_school_dome) ==
               :fail
    end

    test "the tree builds it before the ordinary draw", %{iid: iid} do
      FleetScenario.spawn_fake_rand(self(), instance_id: iid, uniform_value: 0.9, random_index: 0)

      assert {:ok, built} = SystemAI.do_action(garrison(iid), 8, :rebel_dominion)
      assert [item] = Queue.to_list(built.queue.queue)
      assert item.prod_key == :military_school_dome
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
