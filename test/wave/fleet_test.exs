defmodule Wave.FleetTest do
  use ExUnit.Case, async: true

  alias Wave.{Fleet, Warlord}

  defp ships, do: Map.new(Data.Game.Ship.Content.Slow.data(), &{&1.key, &1})

  defp yard(id, shipyards, levels \\ %{}) do
    %{
      id: id,
      sector_id: 1,
      production: 600.0,
      shipyards: shipyards,
      levels: Map.merge(%{fighter: 0.0, corvette: 0.0, frigate: 0.0, capital: 0.0}, levels)
    }
  end

  defp army(filled) do
    %{tiles: for(id <- 1..18, do: %{id: id, ship_status: if(id in filled, do: :filled, else: :empty)})}
  end

  describe "role_weights/2 and quotas/2" do
    @knob %{
      "early" => %{"defense" => 40, "raid" => 60},
      "late" => %{"defense" => 30, "raid" => 25, "siege" => 15, "conquest" => 10, "screen" => 20}
    }

    test "a stage reads its own weights over every role, or the nearest earlier stage's" do
      assert Fleet.role_weights(@knob, :early) == %{defense: 40.0, raid: 60.0, siege: 0.0, conquest: 0.0, screen: 0.0}
      assert Fleet.role_weights(@knob, :mid) == Fleet.role_weights(@knob, :early)
      assert Fleet.role_weights(@knob, :late).conquest == 10.0
      assert Fleet.role_weights(%{}, :late) |> Map.values() |> Enum.sum() == 0.0
    end

    test "the roster is split in whole fleets that add up to the ceiling" do
      weights = Fleet.role_weights(@knob, :late)

      assert Fleet.quotas(10, weights) == %{defense: 3, raid: 3, siege: 1, conquest: 1, screen: 2}
      assert Fleet.quotas(4, weights) == %{defense: 1, raid: 1, siege: 1, conquest: 0, screen: 1}
      assert Fleet.quotas(1, weights) == %{defense: 1, raid: 0, siege: 0, conquest: 0, screen: 0}

      for ceiling <- 1..40,
          do: assert(weights |> then(&Fleet.quotas(ceiling, &1)) |> Map.values() |> Enum.sum() == ceiling)

      assert Fleet.quotas(0, weights) |> Map.values() |> Enum.sum() == 0
      assert Fleet.quotas(5, Fleet.role_weights(%{}, :late)) |> Map.values() |> Enum.sum() == 0
    end

    test "the next hire takes the role furthest below its share" do
      quotas = %{defense: 3, raid: 3, siege: 1, conquest: 1, screen: 2}

      assert Fleet.role_order(quotas, %{}) == [:defense, :raid, :screen, :siege, :conquest]
      assert Fleet.role_order(quotas, %{defense: 3, raid: 1}) == [:raid, :screen, :siege, :conquest]
      assert Fleet.role_order(quotas, quotas) == []
    end
  end

  describe "shipyards" do
    test "a military system is a yard, and it keeps its shipyards and class experience" do
      tile = fn key, status -> %{building_key: key, building_status: status} end

      system =
        struct(Instance.StellarSystem.StellarSystem,
          id: 7,
          sector_id: 3,
          ai_profile: :defense,
          production: %{value: 729.4},
          fighter_lvl: %{value: 12},
          corvette_lvl: %{value: 9.5},
          frigate_lvl: nil,
          capital_lvl: nil,
          bodies: [
            %{
              tiles: [tile.(:infra_open, :built), tile.(:factory_open, :built)],
              bodies: [
                %{tiles: [tile.(:shipyard_2_orbital, :built), tile.(nil, :empty)], bodies: []},
                %{tiles: [tile.(:shipyard_1_orbital, :built), tile.(:shipyard_3_orbital, :empty)], bodies: []}
              ]
            }
          ]
        )

      assert Fleet.yard(system) == %{
               id: 7,
               sector_id: 3,
               production: 729.4,
               shipyards: [:shipyard_1_orbital, :shipyard_2_orbital],
               levels: %{fighter: 12.0, corvette: 9.5, frigate: 0.0, capital: 0.0}
             }

      assert Fleet.yard_profile?(:defense, ["defense"])
      refute Fleet.yard_profile?(:production, ["defense"])
      assert Fleet.yard_profile?(:production, ["defense", "production"])
      refute Fleet.yard_profile?(nil, ["defense"])
    end

    test "a yard lays down only the hulls whose shipyard stands there; a Carrier needs none" do
      catalog = ships()
      fighters_only = yard(1, [:shipyard_1_orbital])

      assert Fleet.can_build?(fighters_only, catalog.fighter_4v3, true)
      refute Fleet.can_build?(fighters_only, catalog.corvette_1, true)
      assert Fleet.can_build?(fighters_only, catalog.transport_2, true)
      assert Fleet.can_build?(fighters_only, catalog.capital_1, false)

      slots = [{1, :fighter_4}, {2, :corvette_1}]
      refute Fleet.builds?(fighters_only, slots, catalog, true)
      assert Fleet.builds?(yard(2, [:shipyard_1_orbital, :shipyard_2_orbital]), slots, catalog, true)
      assert Fleet.builds?(fighters_only, slots, catalog, false)
    end

    test "a new fleet goes to the freest capable yard, then to the one that trains its ships best" do
      catalog = ships()
      slots = [{1, :fighter_4}, {2, :fighter_4}]

      green = yard(1, [:shipyard_1_orbital])
      veteran = yard(2, [:shipyard_1_orbital], %{fighter: 36.0})
      wrong = yard(3, [:shipyard_3_orbital], %{fighter: 99.0})
      yards = [green, veteran, wrong]

      assert Fleet.pick_yard(yards, slots, catalog, %{}, true).id == 2
      assert Fleet.pick_yard(yards, slots, catalog, %{2 => 1}, true).id == 1
      assert Fleet.pick_yard(yards, slots, catalog, %{1 => 1, 2 => 1}, true).id == 2
      assert Fleet.pick_yard([wrong], slots, catalog, %{}, true) == nil

      assert Fleet.initial_xp(veteran, catalog.fighter_4) == 36.0
      assert Fleet.initial_xp(veteran, catalog.transport_2) == 0.0
    end
  end

  describe "construction" do
    @slots [{1, :fighter_4}, {2, :fighter_4}, {4, :corvette_1}]

    test "ships are laid down in tile order into the empty tiles only" do
      assert Fleet.next_ship(@slots, army([])) == {1, :fighter_4}
      assert Fleet.next_ship(@slots, army([1])) == {2, :fighter_4}
      assert Fleet.next_ship(@slots, army([1, 2, 4])) == nil
      # A refit fills the gaps and leaves what survived where it is.
      assert Fleet.next_ship(@slots, army([1, 4])) == {2, :fighter_4}

      assert Fleet.missing(@slots, army([1])) == 2
      assert Fleet.missing_share(@slots, 1) == 2 / 3
      assert Fleet.missing_share(@slots, 5) == 0.0
    end

    test "a fleet of eighteen takes ninety time units at one ship per five, whatever it is made of" do
      catalog = ships()
      swarm = for tile <- 1..18, do: {tile, :fighter_4v3}
      cruisers = for tile <- 1..18, do: {tile, :capital_2}

      assert Fleet.build_ut(yard(1, []), swarm, catalog, 5.0, 0) == 90.0
      assert Fleet.build_ut(yard(1, []), cruisers, catalog, 5.0, 0) == 90.0
    end

    test "a capital ship holds the yard for an hour, whatever else the interval is" do
      catalog = ships()
      by_class = %{"capital" => 20.0}

      assert Fleet.class_interval(catalog.capital_2, 5.0, by_class) == 20.0
      assert Fleet.class_interval(catalog.frigate_2v2, 5.0, by_class) == 5.0
      assert Fleet.class_interval(catalog.capital_2, 5.0, %{}) == 5.0
      assert Fleet.class_interval(catalog.capital_2, 5.0, "nonsense") == 5.0
    end

    test "at the production pace a yard pays for the hull like a player's system, never under the interval" do
      catalog = ships()
      yard = yard(1, [])

      # 1,408 production in a 600-production yard is 2.3 ut: the interval holds.
      assert Fleet.ship_ut(yard, catalog.fighter_4v3, 5.0, 1.0) == 5.0
      assert Fleet.ship_ut(yard, catalog.capital_2, 5.0, 1.0) == 200.0
      assert Fleet.ship_ut(yard, catalog.capital_2, 5.0, 2.0) == 100.0
      assert Fleet.ship_ut(%{yard | production: 0.0}, catalog.capital_2, 5.0, 1.0) == 5.0
    end
  end

  describe "posts" do
    test "shipyards are garrisoned first, then the most productive systems" do
      systems = [%{id: 1, production: 900.0}, %{id: 2, production: 300.0}, %{id: 3, production: 500.0}]
      assert Fleet.rank_posts(systems, MapSet.new([2])) == [2, 1, 3]
    end

    test "three defenders in five stand on the border, and no post has two before every post has one" do
      border = [10, 11]
      core = [20, 21, 22]

      posted =
        Enum.reduce(1..8, [], fn _n, posted -> posted ++ [Fleet.defense_post(posted, border, core, 0.6)] end)

      assert posted == [10, 11, 20, 10, 21, 11, 10, 22]
      assert Enum.count(Enum.take(posted, 5), &(&1 in border)) == 3
    end

    test "with only one kind of sector every defender goes there" do
      assert Fleet.defense_post([], [], [20, 21], 0.6) == 20
      assert Fleet.defense_post([20], [], [20, 21], 0.6) == 21
      assert Fleet.defense_post([10], [10, 11], [], 0.6) == 11
      assert Fleet.defense_post([], [], [], 0.6) == nil
    end
  end

  describe "the Warlord's fleet books" do
    defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

    test "fleets are off unless the game switches them on, and the ceiling may be zero" do
      refute Warlord.fleets_enabled?(warlord())
      # Day 1 of the curve is 0: no fleets, where an agent ceiling would floor at 1.
      assert warlord() |> Warlord.gauge(:human_players, 11) |> Warlord.fleet_ceiling() == 0

      day9 = warlord() |> Warlord.gauge(:human_players, 11) |> Warlord.advance(8.85 * 480)
      assert Warlord.fleet_ceiling(day9) == 6

      day16 = warlord() |> Warlord.gauge(:human_players, 11) |> Warlord.advance(15.5 * 480)
      assert Warlord.fleet_ceiling(day16) == 22
    end

    test "a snapshot from before fleets restores with empty books" do
      old = Map.drop(warlord(), [:fleets, :fleet_accum, :system_profiles, :yards, :yards_at, :yard_clock])
      state = old |> Warlord.upgrade() |> Warlord.advance(2.0)

      assert Warlord.fleets(state) == %{}
      assert state.fleet_accum == 2.0
      assert Warlord.yards_due?(state, 120.0)
    end

    test "the hire clock: due after an interval, held at a full roster, deferred with nothing to build" do
      state = Warlord.advance(warlord(), 59.0)
      refute Warlord.fleet_hire_due?(state)

      state = Warlord.advance(state, 2.5)
      assert Warlord.fleet_hire_due?(state)
      assert Warlord.consume_fleet_hire(state).fleet_accum == 1.5

      held = state |> Warlord.advance(500.0) |> Warlord.hold_fleet_hire()
      assert held.fleet_accum == 60.0
      refute state |> Warlord.defer_fleet_hire() |> Warlord.fleet_hire_due?()
    end

    test "a yard lays one ship per interval and keeps its rhythm when a pass runs late" do
      state =
        warlord()
        |> Warlord.advance(100.0)
        |> Warlord.put_yards(%{5 => :defense}, %{5 => yard(5, [:shipyard_1_orbital])})
        |> Warlord.track_fleet(1, :raid, "bp", [{1, :fighter_4}, {2, :fighter_4}], 5)

      assert Warlord.yard_ready?(state, 5)
      assert Warlord.yard_load(state) == %{5 => 1}

      state = Warlord.ship_laid(state, 1, 5)
      assert Warlord.fleets(state)[1].laid == 1
      refute Warlord.yard_ready?(state, 5)
      refute state |> Warlord.advance(4.0) |> Warlord.yard_ready?(5)

      # The pass comes 0.6 late: the ship after it is still due at 110, not 110.6.
      late = Warlord.advance(state, 5.6)
      assert Warlord.yard_ready?(late, 5)
      late = Warlord.ship_laid(late, 1, 5)
      assert late.yard_clock[5] == 110.0

      # A costly hull keeps the yard busy for as long as the agent says.
      slow = Warlord.ship_laid(late, 1, 5, 200.0)
      assert slow.yard_clock[5] == 310.0

      # A yard that stood idle starts over instead of banking the idle time.
      idle = late |> Warlord.advance(300.0) |> Warlord.ship_laid(1, 5)
      refute Warlord.yard_ready?(idle, 5)
      assert idle |> Warlord.advance(5.0) |> Warlord.yard_ready?(5)
    end

    test "stages, counts and waits" do
      state =
        warlord()
        |> Warlord.track_fleet(1, :raid, "a", [{1, :fighter_4}], 5)
        |> Warlord.track_fleet(2, :defense, "b", [{1, :fighter_4}], 6)
        |> Warlord.advance(10.0)
        |> Warlord.fleet_stage(2, :posted, %{post: 9})

      assert Warlord.fleet_counts(state) == %{defense: 1, raid: 1, siege: 0, conquest: 0, screen: 0}
      assert Warlord.yard_load(state) == %{5 => 1}
      assert %{stage: :posted, post: 9, since: 10.0} = Warlord.fleets(state)[2]

      assert Warlord.fleet_wait(state, 1, 20.0) |> Warlord.fleets() |> get_in([1, :retry_at]) == 30.0
      assert state |> Warlord.forget_fleet(1) |> Warlord.fleets() |> Map.keys() == [2]
      assert Warlord.fleet_stage(state, 99, :posted) == state

      assert %{fleets: %{1 => %{role: :raid, stage: :building, ships: 1}}} = Warlord.summary(state)
    end

    test "a survey forgets the clocks of yards that are gone" do
      state =
        warlord()
        |> Warlord.put_yards(%{5 => :defense, 6 => :defense}, %{5 => yard(5, []), 6 => yard(6, [])})
        |> Warlord.ship_laid(1, 5)
        |> Warlord.ship_laid(1, 6)
        |> Warlord.advance(130.0)

      assert Warlord.yards_due?(state, 120.0)
      state = Warlord.put_yards(state, %{5 => :defense}, %{5 => yard(5, [])})
      assert Map.keys(state.yard_clock) == [5]
      refute Warlord.yards_due?(state, 120.0)
    end
  end
end
