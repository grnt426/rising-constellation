defmodule Wave.DoctrineTest do
  use ExUnit.Case, async: true

  alias Wave.{Blueprints, Doctrine, Warlord}

  defp ships, do: Map.new(Data.Game.Ship.Content.Slow.data(), &{&1.key, &1})

  # What the humans of instance 185 held on day 9.
  @day9 [:shipyard_1, :fighter_2, :fighter_3, :fighter_4, :merge_fighter_1, :merge_fighter_2] ++
          [:shipyard_2, :corvette_1, :merge_corvette_1, :shipyard_3]

  defp layout(hulls), do: hulls |> Enum.with_index(1) |> Enum.map(fn {hull, tile} -> {tile, hull} end)

  defp base(hulls), do: %{id: "bp_x", slots: layout(hulls), stance: :defend, evidence: %{"raid" => 1}, players: 1}

  defp identity(hulls \\ [:fighter_4, :fighter_4, :corvette_1]) do
    Doctrine.new(base(hulls), "bp_x.1", 100.0, %{}, [], 0, 0)
  end

  describe "the hulls a fleet may be built from" do
    test "only what the humans have unlocked, base hulls only" do
      assert Blueprints.hulls(ships(), @day9) ==
               [:corvette_1, :fighter_1, :fighter_2, :fighter_3, :fighter_4, :frigate_1]

      # Nothing the humans hold, nothing to build.
      assert Blueprints.hulls(ships(), []) == []
    end

    test "a hull's stand-ins are the other unlocked hulls of its class, else of the class next to it" do
      alternatives = Doctrine.alternatives(ships(), Blueprints.hulls(ships(), @day9))

      assert alternatives.fighter_4 == [:fighter_1, :fighter_2, :fighter_3]
      # One corvette hull and one frigate hull unlocked: they borrow next door.
      assert alternatives.corvette_1 == [:fighter_1, :fighter_2, :fighter_3, :fighter_4, :frigate_1]
      assert alternatives.frigate_1 == [:corvette_1]
      refute Map.has_key?(alternatives, :corvette_2)
    end

    test "capitals only trade with capitals, and Carriers with nothing" do
      every = ships() |> Map.values() |> Enum.map(& &1.patent) |> Enum.reject(&is_nil/1)
      alternatives = Doctrine.alternatives(ships(), Blueprints.hulls(ships(), every))

      assert alternatives.capital_1 == [:capital_2, :capital_3]
      assert alternatives.frigate_2 == [:frigate_1, :frigate_3, :frigate_4]
      assert alternatives.corvette_1 == [:corvette_2, :corvette_3]
      refute Map.has_key?(alternatives, :transport_2)

      # A lone capital hull has no stand-in: nothing crosses into capitals or out.
      lone = Doctrine.alternatives(ships(), [:frigate_1, :capital_1])
      assert lone.capital_1 == []
      assert lone.frigate_1 == []
    end
  end

  describe "fuzz/5" do
    setup do
      %{alternatives: Doctrine.alternatives(ships(), Blueprints.hulls(ships(), @day9))}
    end

    test "a swap gives one tile a stand-in and leaves the rest alone", %{alternatives: alternatives} do
      slots = layout([:fighter_4, :fighter_4, :corvette_1, :transport_2])

      # First die: which tile (of the three that have a stand-in). Second: which hull.
      assert Doctrine.fuzz(slots, alternatives, [0.6, 0.99], 1, 0) ==
               [{1, :fighter_4}, {2, :fighter_3}, {3, :corvette_1}, {4, :transport_2}]

      assert Doctrine.fuzz(slots, alternatives, [0.0, 0.0], 1, 0) ==
               [{1, :fighter_1}, {2, :fighter_4}, {3, :corvette_1}, {4, :transport_2}]
    end

    test "a move exchanges two tiles holding different hulls", %{alternatives: alternatives} do
      slots = layout([:fighter_4, :fighter_4, :corvette_1])

      assert Doctrine.fuzz(slots, alternatives, [0.0, 0.0], 0, 1) == [
               {1, :corvette_1},
               {2, :fighter_4},
               {3, :fighter_4}
             ]

      # One hull only: nothing to exchange.
      assert Doctrine.fuzz(layout([:corvette_1, :corvette_1]), alternatives, [0.0, 0.0], 0, 1) ==
               layout([:corvette_1, :corvette_1])
    end

    test "the tiles and the ship count never change, and the fuzz stops when the dice run out", %{
      alternatives: alternatives
    } do
      slots = layout(List.duplicate(:fighter_4, 12) ++ List.duplicate(:corvette_1, 6))
      dice = for n <- 1..40, do: rem(n * 37, 100) / 100

      fuzzed = Doctrine.fuzz(slots, alternatives, dice, 3, 2)

      assert Enum.map(fuzzed, &elem(&1, 0)) == Enum.to_list(1..18)
      assert fuzzed != slots
      # Three swaps at most: fifteen tiles or more still hold what they held.
      assert Enum.count(fuzzed, fn {_tile, hull} -> hull in [:fighter_4, :corvette_1] end) >= 15
      assert Doctrine.fuzz(slots, alternatives, [0.5], 3, 2) == slots
    end
  end

  describe "capital ships" do
    test "one from the day the humans field one, one more every thirty hours, six at most" do
      assert Doctrine.capital_allowance(nil, 5_000.0, 600.0, 6) == 0
      assert Doctrine.capital_allowance(1_000.0, 1_000.0, 600.0, 6) == 1
      assert Doctrine.capital_allowance(1_000.0, 1_599.0, 600.0, 6) == 1
      assert Doctrine.capital_allowance(1_000.0, 1_600.0, 600.0, 6) == 2
      assert Doctrine.capital_allowance(1_000.0, 4_000.0, 600.0, 6) == 6
      assert Doctrine.capital_allowance(1_000.0, 90_000.0, 600.0, 6) == 6
    end

    test "capitals past the allowance are built as the hull the design has most of" do
      catalog = ships()
      slots = layout([:capital_2, :frigate_2, :capital_1, :frigate_2, :frigate_3, :capital_3, :transport_2])
      substitute = Doctrine.capital_substitute(slots, catalog, [:frigate_1, :frigate_2, :frigate_3])

      assert substitute == :frigate_2

      assert Doctrine.cap_capitals(slots, catalog, 1, substitute) ==
               layout([:capital_2, :frigate_2, :frigate_2, :frigate_2, :frigate_3, :frigate_2, :transport_2])

      assert Doctrine.cap_capitals(slots, catalog, 6, substitute) == slots
      assert Doctrine.capitals(Doctrine.cap_capitals(slots, catalog, 2, substitute), catalog) == 2
    end

    test "an all-capital design falls back to the costliest unlocked hull below capitals" do
      catalog = ships()
      slots = layout([:capital_1, :capital_1, :capital_2])

      assert Doctrine.capital_substitute(slots, catalog, [:fighter_4, :corvette_1, :frigate_1]) == :frigate_1
      assert Doctrine.cap_capitals(slots, catalog, 0, nil) == []
    end

    test "the library's draw is costed with the cap on" do
      catalog = ships()
      every = catalog |> Map.values() |> Enum.map(& &1.patent) |> Enum.reject(&is_nil/1)

      shape = fn slots ->
        Doctrine.cap_capitals(slots, catalog, 1, Doctrine.capital_substitute(slots, catalog, [:frigate_2]))
      end

      for pick <- Blueprints.draw_pool(Blueprints.pool(), :siege, every, catalog, shape: shape) do
        assert Enum.count(pick.slots, fn {_tile, key} -> catalog[key].class == :capital end) <= 1
      end

      dearest = fn opts ->
        Blueprints.pool()
        |> Blueprints.draw_pool(:siege, every, catalog, opts)
        |> Enum.map(& &1.production)
        |> Enum.max()
      end

      assert dearest.(shape: shape) < dearest.([])
    end
  end

  describe "the daily review" do
    test "results are wins and losses, whatever the engine called them" do
      assert Doctrine.outcome(:victorious) == :win
      assert Doctrine.outcome(:critical_success) == :win
      assert Doctrine.outcome(:fleeing) == :loss
      assert Doctrine.outcome(:dead) == :loss
      assert Doctrine.outcome(:normal_failure) == :loss
      assert Doctrine.outcome(:whatever) == nil
    end

    test "too few results judge nothing; a majority of wins is winning; a third or less is losing" do
      fresh = identity()
      one_loss = Doctrine.record(fresh, :loss)
      two_one = fresh |> Doctrine.record(:win) |> Doctrine.record(:win) |> Doctrine.record(:loss)
      one_two = fresh |> Doctrine.record(:win) |> Doctrine.record(:loss) |> Doctrine.record(:loss)
      split = fresh |> Doctrine.record(:win) |> Doctrine.record(:loss)

      assert Doctrine.verdict(fresh, 2, 0.5, 0.34) == :unproven
      assert Doctrine.verdict(one_loss, 2, 0.5, 0.34) == :unproven
      assert Doctrine.verdict(two_one, 2, 0.5, 0.34) == :winning
      assert Doctrine.verdict(split, 2, 0.5, 0.34) == :winning
      assert Doctrine.verdict(one_two, 2, 0.5, 0.34) == :losing
    end

    test "a winner is fuzzed again and keeps its lineage" do
      alternatives = Doctrine.alternatives(ships(), Blueprints.hulls(ships(), @day9))
      winner = identity() |> Doctrine.record(:win) |> Doctrine.record(:win)

      assert {:refuzz, closed} = Doctrine.review(%{winner | strikes: 1}, :winning, forgiveness: 1)
      assert %{wins: 0, losses: 0, strikes: 0, total_wins: 2} = closed

      next = Doctrine.refuzz(closed, alternatives, [0.0, 0.0, 0.0, 0.9], 1, 1)
      assert next.id == winner.id
      assert next.generation == 2
      assert next.slots != winner.slots
    end

    test "a loser is forgiven once, then replaced" do
      loser = identity() |> Doctrine.record(:loss) |> Doctrine.record(:loss)

      assert {:keep, warned} = Doctrine.review(loser, :losing, forgiveness: 1)
      assert %{strikes: 1, wins: 0, losses: 0, total_losses: 2} = warned

      again = warned |> Doctrine.record(:loss) |> Doctrine.record(:loss)
      assert {:replace, _gone} = Doctrine.review(again, :losing, forgiveness: 1)

      # No forgiveness at all replaces on the first bad day.
      assert {:replace, _gone} = Doctrine.review(loser, :losing, forgiveness: 0)
      # A good day in between clears the strike.
      assert {:refuzz, %{strikes: 0}} = Doctrine.review(warned, :winning, forgiveness: 1)
    end

    test "an unproven identity stays unless the library has moved on; a winner stays even then" do
      assert {:keep, _} = Doctrine.review(identity(), :unproven, forgiveness: 1)
      assert {:replace, _} = Doctrine.review(identity(), :unproven, forgiveness: 1, outdated?: true)
      assert {:refuzz, _} = Doctrine.review(identity(), :winning, forgiveness: 1, outdated?: true)
    end
  end

  describe "the Warlord's book" do
    defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

    test "identities are numbered, kept per role, and the review clock starts with the first" do
      state = Warlord.advance(warlord(), 50.0)
      refute Warlord.review_due?(state, 480.0)

      {id, state} = Warlord.next_design_id(state, "bp_x")
      {id2, state} = Warlord.next_design_id(state, "bp_x")
      assert {id, id2} == {"bp_x.1", "bp_x.2"}

      state = Warlord.put_identity(state, :raid, %{identity() | id: id})
      state = Warlord.put_identity(state, :raid, %{identity() | id: id2})
      assert Enum.map(Warlord.identities(state, :raid), & &1.id) == [id, id2]
      assert Warlord.identities(state, :siege) == []

      refute state |> Warlord.advance(479.0) |> Warlord.review_due?(480.0)
      later = Warlord.advance(state, 480.0)
      assert Warlord.review_due?(later, 480.0)
      refute later |> Warlord.mark_reviewed() |> Warlord.review_due?(480.0)

      assert state |> Warlord.drop_identity(:raid, id) |> Warlord.identities(:raid) |> Enum.map(& &1.id) == [id2]
    end

    test "a fleet's result goes to the identity it was built from, and to no one else" do
      state =
        warlord()
        |> Warlord.put_identity(:raid, identity())
        |> Warlord.track_fleet(7, :raid, "bp_x.1", [{1, :fighter_4v3}], 5)
        |> Warlord.track_fleet(8, :raid, "bp_gone.9", [{1, :fighter_4v3}], 5)

      assert {state, %{wins: 1, total_wins: 1}} = Warlord.fleet_result(state, 7, :win)
      assert {state, %{wins: 1, losses: 1}} = Warlord.fleet_result(state, 7, :loss)
      # A coloniser, and a fleet whose identity was replaced since it was built.
      assert {^state, nil} = Warlord.fleet_result(state, 99, :win)
      assert {^state, nil} = Warlord.fleet_result(state, 8, :loss)

      assert %{doctrine: %{raid: [%{id: "bp_x.1", wins: 1, losses: 1, window: [1, 1]}]}} = Warlord.summary(state)
    end

    test "the humans' hulls only ever grow, and the capital clock starts when one of them is a capital" do
      state = warlord() |> Warlord.advance(100.0) |> Warlord.learn_hulls([:shipyard_1, :fighter_4], false)
      assert Warlord.capital_allowance(state) == 0

      state = state |> Warlord.advance(900.0) |> Warlord.learn_hulls([:fighter_4, :capital_1], true)
      assert Warlord.human_hulls(state) == [:shipyard_1, :fighter_4, :capital_1]
      assert state.capital_since == 1000.0
      assert Warlord.capital_allowance(state) == 1

      # The player who held it leaves: nothing is forgotten, the clock runs on.
      state = state |> Warlord.advance(1300.0) |> Warlord.learn_hulls([:fighter_4], false)
      assert :capital_1 in Warlord.human_hulls(state)
      assert Warlord.capital_allowance(state) == 3
      assert state |> Warlord.advance(48_000.0) |> Warlord.capital_allowance() == 6
    end

    test "the sector pace clock runs faster from each breakpoint on" do
      assert Warlord.warp(1000.0, []) == 1000.0
      assert Warlord.warp(1000.0, [{4320.0, 2}]) == 1000.0
      # Two days at double pace are worth four.
      assert Warlord.warp(4320.0 + 960.0, [{4320.0, 2}]) == 4320.0 + 1920.0
      # Then four times: one more day is worth four.
      assert Warlord.warp(4320.0 + 960.0 + 480.0, [{4320.0, 2}, {5280.0, 4}]) == 4320.0 + 1920.0 + 1920.0
      assert Warlord.pace_elapsed(Warlord.advance(warlord(), 777.0)) == 777.0
      refute Warlord.contested_open?(warlord())
    end
  end
end
