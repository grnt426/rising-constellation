defmodule Wave.ErasedTest do
  use ExUnit.Case, async: true

  alias Wave.Erased

  # The spy table from Data.Game.Content.Character: informer 0, assassin 1,
  # saboteur 2, then the three non-offensive specializations.
  defp spy_specs do
    [
      %{key: :informer, index: 0, bonus: [%Core.Bonus{from: :direct, value: 20, type: :add, to: :spy_infiltrate}]},
      %{key: :assassin, index: 1, bonus: [%Core.Bonus{from: :direct, value: 18, type: :add, to: :spy_assassination}]},
      %{key: :saboteur, index: 2, bonus: [%Core.Bonus{from: :direct, value: 18, type: :add, to: :spy_sabotage}]},
      %{key: :counter_spy, index: 3, bonus: [%Core.Bonus{from: :direct, value: 10, type: :add, to: :sys_ci}]},
      %{key: :cleaner, index: 4, bonus: [%Core.Bonus{from: :direct, value: 10, type: :add, to: :sys_remove_contact}]},
      %{key: :mafioso, index: 5, bonus: [%Core.Bonus{from: :sys_credit, value: 0.05, type: :mul, to: :sys_credit}]}
    ]
  end

  describe "skills" do
    test "reads the three offensive specializations by index" do
      assert Erased.skill_points([2, 3, 4, 9, 9, 9]) == %{infiltration: 2, removal: 3, sabotage: 4}
      assert Erased.skill_points(nil) == %{infiltration: 0, removal: 0, sabotage: 0}
    end

    test "strength is the bonus the points actually grant" do
      assert Erased.strength([0, 3, 0, 0, 0, 0], spy_specs(), :spy_assassination) == 54
      assert Erased.strength([0, 3, 0, 0, 0, 0], spy_specs(), :spy_sabotage) == 0
    end

    test "an agent with points only in the desk jobs is worth no roster slot" do
      assert Erased.offensive_strength([0, 0, 0, 4, 4, 4], spy_specs()) == 0
      assert Erased.offensive_strength([1, 0, 0, 0, 0, 0], spy_specs()) == 20
    end
  end

  describe "postings" do
    test "the theatre roll honours the home share" do
      assert Erased.theatre(0.1, 0.25) == :home
      assert Erased.theatre(0.25, 0.25) == :field
      assert Erased.theatre(0.9, 0.25) == :field
    end

    test "home duty needs points across removal and sabotage, from either or both" do
      assert Erased.fit_for_home_duty?([0, 2, 0, 0, 0, 0], 2)
      assert Erased.fit_for_home_duty?([0, 1, 1, 0, 0, 0], 2)
      refute Erased.fit_for_home_duty?([5, 1, 0, 0, 0, 0], 2)
    end

    test "duty weights are scaled by the points the agent holds" do
      weights = %{removal: 50, sabotage: 50}

      # A pure saboteur: removal keeps weight 50, sabotage is 50 * (1 + 4).
      # Sorted alphabetically, removal occupies the first 50/300 of the roll.
      assert Erased.duty(0.1, weights, [0, 0, 4, 0, 0, 0]) == :removal
      assert Erased.duty(0.5, weights, [0, 0, 4, 0, 0, 0]) == :sabotage
    end

    test "a duty an agent has no points for is still reachable, just rarely" do
      weights = %{removal: 50, sabotage: 50}
      assert Erased.duty(0.0, weights, [0, 0, 9, 0, 0, 0]) == :removal
    end

    test "with no usable weights at all an agent falls back to infiltration" do
      assert Erased.duty(0.5, %{}, [1, 1, 1, 0, 0, 0]) == :infiltration
    end
  end

  describe "training" do
    test "the target is drawn across the whole inclusive range" do
      assert Erased.train_target(0.0, 3, 6) == 3
      assert Erased.train_target(0.99, 3, 6) == 6
      assert Erased.train_target(0.5, 3, 6) in 3..6
    end

    test "a trainee graduates on its informer points, not its total" do
      refute Erased.trained?([2, 5, 5, 0, 0, 0], 4)
      assert Erased.trained?([4, 0, 0, 0, 0, 0], 4)
    end

    test "graduation only offers the home posting to an agent fit for it" do
      opts = [
        home_share: 1.0,
        min_points: 2,
        home_weights: %{removal: 50, sabotage: 50},
        field_weights: %{infiltration: 40, removal: 30, sabotage: 30}
      ]

      # Rolled home, and holds the points for it.
      assert {:home, _duty} = Erased.graduate([5, 2, 0, 0, 0, 0], {0.0, 0.5}, opts)

      # Rolled home, but all its points went into informer: the field takes it.
      assert {:field, _duty} = Erased.graduate([6, 1, 0, 0, 0, 0], {0.0, 0.5}, opts)
    end

    test "a home share of zero always sends a graduate to the field" do
      opts = [
        home_share: 0.0,
        min_points: 2,
        home_weights: %{removal: 50, sabotage: 50},
        field_weights: %{infiltration: 40, removal: 30, sabotage: 30}
      ]

      assert {:field, _duty} = Erased.graduate([5, 3, 3, 0, 0, 0], {0.0, 0.5}, opts)
    end
  end

  describe "target rules" do
    test "governors are for seducers only: never removed, never sabotaged" do
      governor = %{type: :admiral, name: "Ediya", level: 4, governor?: true, tiles: 12, colony_ship?: true}
      refute Erased.removable?(governor)
      refute Erased.worth_sabotaging?(governor, 6)
      assert Erased.removable?(%{governor | governor?: false})
    end

    test "a level-1 replacement officer is left alone, and a promoted one is not" do
      cmo = %{type: :admiral, name: "CMO #0001-0002", level: 1}
      assert Erased.replacement_officer?(cmo)
      refute Erased.removable?(cmo)
      assert Erased.removable?(%{cmo | level: 2})
    end

    test "an ordinary level-1 Navarch is fair game" do
      assert Erased.removable?(%{type: :admiral, name: "Kira Vance", level: 1})
    end

    test "a system is not a removal target" do
      refute Erased.removable?(%{type: :stellar_system, name: "x", level: 5})
    end

    test "sabotage skips fleets already broken below the threshold" do
      fleet = fn tiles -> %{type: :admiral, tiles: tiles, colony_ship?: false} end
      assert Erased.worth_sabotaging?(fleet.(6), 6)
      refute Erased.worth_sabotaging?(fleet.(5), 6)
      assert Erased.worth_sabotaging?(fleet.(5), 4)
    end

    test "a colony ship is worth stopping at any size" do
      assert Erased.worth_sabotaging?(%{type: :admiral, tiles: 1, colony_ship?: true}, 6)
    end

    test "an unread fleet is judged on its tile count alone" do
      refute Erased.worth_sabotaging?(%{type: :admiral, tiles: 2, colony_ship?: nil}, 6)
    end

    test "only Navarchs can be sabotaged — the engine refuses anything else" do
      refute Erased.worth_sabotaging?(%{type: :spy, tiles: 9, colony_ship?: true}, 6)
    end

    test "a system the Rebellion already sees whole is not worth infiltrating" do
      assert Erased.worth_infiltrating?(4)
      refute Erased.worth_infiltrating?(5)
      refute Erased.worth_infiltrating?(nil)
    end
  end

  describe "borrowed sight" do
    test "a target seen only through our own agent is struck near, never travelled to" do
      borrowed = %{id: 1, transient?: true}

      assert Erased.committable?(borrowed, 0, 1)
      assert Erased.committable?(borrowed, 1, 1)
      refute Erased.committable?(borrowed, 2, 1)
      refute Erased.committable?(borrowed, 7, 1)
    end

    test "sight from informers keeps, so it carries any distance" do
      stored = %{id: 1, transient?: false}
      assert Erased.committable?(stored, 9, 1)
    end

    test "a hostile from before the flag existed is treated as solidly seen" do
      assert Erased.committable?(%{id: 1}, 9, 1)
    end
  end

  describe "scouting" do
    defp sys(id, status), do: %{id: id, status: status}

    test "goes only where the Rebellion has never been, of any kind, within reach" do
      systems = [
        sys(1, :inhabited_player),
        sys(2, :inhabited_dominion),
        sys(3, :inhabited_neutral),
        sys(4, :uninhabited)
      ]

      distances = %{1 => 2, 2 => 3, 3 => 1, 4 => 1}
      never = fn _id -> false end

      # An empty system is a colony site worth knowing about.
      assert Erased.explore_targets(systems, never, 6, distances) |> Enum.map(& &1.id) == [1, 2, 3, 4]

      seen = fn id -> id in [1, 4] end
      assert Erased.explore_targets(systems, seen, 6, distances) |> Enum.map(& &1.id) == [2, 3]
      assert Erased.explore_targets(systems, never, 2, distances) |> Enum.map(& &1.id) == [1, 3, 4]
    end

    test "never picks the system it already stands in, or one it cannot reach" do
      systems = [sys(1, :inhabited_player), sys(2, :inhabited_player)]
      assert Erased.explore_targets(systems, fn _ -> false end, 6, %{1 => 0}) == []
    end

    # i185: a lone Erased walked Zaphar ↔ Alnoria nine times, because the rule
    # was "nearest system below visibility 2" and the one it had just left
    # dropped back below 2. A system once seen stays seen.
    test "the system just left is seen, so two neighbours never trade places" do
      systems = [sys(299, :inhabited_neutral), sys(300, :inhabited_neutral), sys(303, :inhabited_neutral)]
      at_300 = %{299 => 1, 300 => 0, 303 => 3}
      seen = fn id -> id in [299, 300] end

      assert Erased.explore_targets(systems, seen, 6, at_300) |> Enum.map(& &1.id) == [303]
    end

    test "nearest first, then dominions, held systems, neutral ground, the rest" do
      order =
        [
          {sys(5, :uninhabited), 1},
          {sys(3, :inhabited_neutral), 1},
          {sys(1, :inhabited_player), 2},
          {sys(2, :inhabited_dominion), 1}
        ]
        |> Enum.sort_by(fn {system, hops} -> Erased.explore_priority(system, hops) end)
        |> Enum.map(fn {system, _hops} -> system.id end)

      assert order == [2, 3, 5, 1]
    end
  end

  describe "forward postings" do
    defp held(id, faction, status), do: %{id: id, faction: faction, status: status}

    # i185 on match day 9: eleven humans, twenty-two Erased.
    test "one scout per three players and one deep infiltrator per five" do
      assert Erased.forward_quotas(11, 0.35, 0.2, 6) == %{scout: 4, deep: 2}
      assert Erased.forward_quotas(15, 0.35, 0.2, 20) == %{scout: 5, deep: 3}
      assert Erased.forward_quotas(1, 0.35, 0.2, 20) == %{scout: 0, deep: 0}
    end

    test "a small roster seats scouts first and deep infiltration with what is left" do
      assert Erased.forward_quotas(11, 0.35, 0.2, 5) == %{scout: 4, deep: 1}
      assert Erased.forward_quotas(11, 0.35, 0.2, 3) == %{scout: 3, deep: 0}
      assert Erased.forward_quotas(11, 0.35, 0.2, 0) == %{scout: 0, deep: 0}
      assert Erased.forward_quotas(11, 0.35, 0.2, -2) == %{scout: 0, deep: 0}
    end

    test "only agents posted forward count against the quotas" do
      roster = %{
        1 => %{theatre: :forward, duty: :scout},
        2 => %{theatre: :forward, duty: :scout},
        3 => %{theatre: :forward, duty: :deep},
        4 => %{theatre: :field, duty: :infiltration},
        5 => %{theatre: :home, duty: :training}
      }

      assert Erased.forward_held(roster) == %{scout: 2, deep: 1}
      assert Erased.forward_held(%{}) == %{scout: 0, deep: 0}
    end

    test "open postings are listed scouts first" do
      assert Erased.forward_vacancies(%{scout: 4, deep: 2}, %{scout: 2, deep: 1}) == [:scout, :scout, :deep]
      assert Erased.forward_vacancies(%{scout: 4, deep: 2}, %{scout: 4, deep: 2}) == []
    end

    # A quota that shrank (players left) never demotes anyone.
    test "a posting held over its quota opens nothing" do
      assert Erased.forward_vacancies(%{scout: 1, deep: 2}, %{scout: 3, deep: 1}) == [:deep]
    end

    test "only an agent with informer points is sent" do
      assert Erased.fit_for_forward?([1, 0, 0, 0, 0, 0], 1)
      refute Erased.fit_for_forward?([0, 7, 3, 0, 0, 0], 1)
      refute Erased.fit_for_forward?([1, 0, 0, 0, 0, 0], 2)
    end

    test "the strongest informer goes first, and between equals the one already infiltrating" do
      order =
        [{20, :sabotage, 477}, {100, :infiltration, 320}, {20, :infiltration, 511}, {40, :removal, 10}]
        |> Enum.sort_by(fn {strength, duty, id} -> Erased.forward_rank(strength, duty, id) end)
        |> Enum.map(&elem(&1, 2))

      assert order == [320, 10, 511, 477]
    end

    test "forward ground is what another faction holds, never neutral or rebel ground" do
      assert Erased.forward_ground?(held(1, :myrmezir, :inhabited_player), :rebellion)
      assert Erased.forward_ground?(held(2, :myrmezir, :inhabited_dominion), :rebellion)
      refute Erased.forward_ground?(held(3, nil, :inhabited_neutral), :rebellion)
      refute Erased.forward_ground?(held(4, :rebellion, :inhabited_player), :rebellion)
      refute Erased.forward_ground?(held(5, :rebellion, :inhabited_dominion), :rebellion)
    end

    # {system id, sector depth from rebel space, hops from the agent}
    defp sweep(duty, ground, chances \\ %{}) do
      ground
      |> Enum.sort_by(fn {id, depth, hops} -> Erased.forward_priority(duty, %{id: id}, depth, chances[id], hops) end)
      |> Enum.map(&elem(&1, 0))
    end

    test "a scout takes the edge nearest rebel space first, whatever lies closer to it" do
      assert sweep(:scout, [{1, 8, 1}, {136, 4, 12}, {80, 5, 2}]) == [136, 80, 1]
    end

    test "a deep infiltrator starts at the far end of the map" do
      assert sweep(:deep, [{136, 4, 1}, {80, 5, 2}, {1, 8, 12}]) == [1, 80, 136]
    end

    test "inside a sector: known soft, then never tried, then known hard, nearest first" do
      ground = [{1, 8, 1}, {2, 8, 3}, {3, 8, 2}, {4, 8, 5}]
      chances = %{2 => 1.0, 3 => 0.3}

      assert sweep(:deep, ground, chances) == [2, 1, 4, 3]
      assert sweep(:scout, ground, chances) == [2, 1, 4, 3]
    end

    test "a sector no adjacency reaches is the last place either posting goes" do
      assert sweep(:scout, [{9, nil, 1}, {1, 8, 9}]) == [1, 9]
      assert sweep(:deep, [{9, nil, 1}, {136, 4, 9}]) == [136, 9]
    end
  end

  describe "practice" do
    test "only below the level cap" do
      assert Erased.trains?(4, 5)
      refute Erased.trains?(5, 5)
      refute Erased.trains?(nil, 5)
    end

    test "any informer point means infiltration; sabotage points alone mean the training Navarch" do
      informer_and_saboteur = [1, 0, 2, 0, 0, 0]
      saboteur = [0, 0, 1, 1, 0, 0]
      remover = [0, 2, 0, 0, 0, 0]

      assert Erased.practice(informer_and_saboteur, true) == :infiltration
      assert Erased.practice(saboteur, true) == :sabotage
      assert Erased.practice(remover, true) == :infiltration
      # No training Navarch in this game: infiltrate, even with no points for it.
      assert Erased.practice(saboteur, false) == :infiltration
    end

    test "a system is unknown until a result reports its Intelligence, then soft or hopeless" do
      assert Erased.practice_odds(nil, 0.25) == :unknown
      assert Erased.practice_odds(0.53, 0.25) == :soft
      assert Erased.practice_odds(0.25, 0.25) == :soft
      assert Erased.practice_odds(0.0, 0.25) == :hopeless
    end

    # With no informer points the attack is 0: an even ratio against an
    # Intelligence of 0, a certain failure against anything more.
    test "a zero-point infiltrator can beat Intelligence 0 and nothing else" do
      assert_in_delta Wave.Intel.success_chance(0, 2, 0), 0.526, 0.001
      assert Wave.Intel.success_chance(0, 2, 2.0) == 0.0
    end

    test "known-soft systems first, best odds first, then unknown ones nearest first" do
      order =
        [
          {sys(1, :inhabited_neutral), nil, 1},
          {sys(2, :inhabited_neutral), 0.53, 4},
          {sys(3, :inhabited_neutral), 0.9, 6},
          {sys(4, :inhabited_neutral), nil, 2}
        ]
        |> Enum.sort_by(fn {system, chance, hops} -> Erased.practice_priority(system, chance, hops) end)
        |> Enum.map(fn {system, _chance, _hops} -> system.id end)

      assert order == [3, 2, 1, 4]
    end
  end

  describe "priorities" do
    test "sabotage puts a siege on our ground first, then a colony ship, then the biggest fleet" do
      siege = %{id: 1, besieging_ours?: true, colony_ship?: false, tiles: 4}
      colony = %{id: 2, besieging_ours?: false, colony_ship?: true, tiles: 1}
      big = %{id: 3, besieging_ours?: false, colony_ship?: false, tiles: 18}

      order =
        [big, colony, siege]
        |> Enum.sort_by(&Erased.sabotage_priority(&1, 1))
        |> Enum.map(& &1.id)

      assert order == [1, 2, 3]
    end

    test "removal takes the best odds first and sorts unknowns behind known ones" do
      good = %{id: 1, level: 2}
      poor = %{id: 2, level: 9}
      blind = %{id: 3, level: 9}

      order =
        [{poor, 0.2}, {blind, nil}, {good, 0.8}]
        |> Enum.sort_by(fn {h, c} -> Erased.removal_priority(h, c, 1) end)
        |> Enum.map(fn {h, _c} -> h.id end)

      assert order == [1, 2, 3]
    end
  end

  describe "slots" do
    test "a target at the cap is closed however the roll lands" do
      candidates = [%{id: 1}]
      committed = fn _ -> 5 end
      assert Erased.admit(candidates, committed, 0.0, 0.35, 5) == []
    end

    test "an empty target is always open" do
      assert Erased.admit([%{id: 1}], fn _ -> 0 end, 0.99, 0.35, 5) == [%{id: 1}]
    end

    test "each extra Erased on a target joins at falloff^n" do
      candidate = %{id: 1}
      admit = fn n, roll -> Erased.admit([candidate], fn _ -> n end, roll, 0.35, 5) end

      # A second joins below 0.35, a third below 0.1225, a fourth below 0.0429.
      assert admit.(1, 0.3) == [candidate]
      assert admit.(1, 0.4) == []
      assert admit.(2, 0.1) == [candidate]
      assert admit.(2, 0.2) == []
      assert admit.(3, 0.05) == []
    end

    test "there is no fallback — a crowded field means the agent waits" do
      candidates = [%{id: 1}, %{id: 2}]
      assert Erased.admit(candidates, fn _ -> 2 end, 0.9, 0.35, 5) == []
    end
  end

  describe "commitments" do
    test "counts the roster by target key, ignoring the asking agent and the idle" do
      roster = %{
        1 => %{target_key: {:character, 99}},
        2 => %{target_key: {:character, 99}},
        3 => %{target_key: {:system, 7}},
        4 => %{target_key: nil}
      }

      assert Erased.commitments(roster) == %{{:character, 99} => 2, {:system, 7} => 1}
      assert Erased.commitments(roster, 2) == %{{:character, 99} => 1, {:system, 7} => 1}
    end

    test "a removed or seduced Erased frees its slot, because the roster is the record" do
      roster = %{1 => %{target_key: {:character, 99}}, 2 => %{target_key: {:character, 99}}}
      assert Erased.commitments(Map.delete(roster, 1)) == %{{:character, 99} => 1}
    end
  end

  describe "telemetry buckets" do
    test "a discovered Erased standing still is resting, not idle" do
      assert Erased.bucket(:idle, true) == :resting
      assert Erased.bucket(:idle, false) == :idle
      assert Erased.bucket(:moving, false) == :moving
      assert Erased.bucket(:assassination, false) == :acting
      assert Erased.bucket(:infiltration, false) == :acting
    end
  end
end
