defmodule Wave.SortieTest do
  use ExUnit.Case, async: true

  alias Wave.{Sortie, Warlord}

  defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

  defp slots(n), do: for(tile <- 1..n, do: {tile, :fighter_1})

  defp fleet(state, id, role),
    do:
      state
      |> Warlord.track_fleet(id, role, "bp_test.1", slots(10), 500)
      |> Warlord.fleet_stage(id, :posted, %{post: 600})

  describe "who strikes" do
    test "raid fleets pillage, siege fleets bombard, conquest fleets invade; the others strike nothing" do
      assert Sortie.action(:raid) == "loot"
      assert Sortie.action(:siege) == "raid"
      assert Sortie.action(:conquest) == "conquest"
      assert Sortie.action(:screen) == nil
      assert Sortie.action(:defense) == nil

      assert Enum.filter([:defense, :raid, :siege, :conquest, :screen], &Sortie.striker?/1) == [
               :raid,
               :siege,
               :conquest
             ]

      assert Sortie.escort?(:screen)
      refute Sortie.escort?(:raid)
      # A screen walks with the fleets that hold a system for long, not with a raid.
      assert Sortie.escorted?(:siege) and Sortie.escorted?(:conquest)
      refute Sortie.escorted?(:raid)
    end

    test "a fleet strikes with the strength its Navarch shows: invasion for a conquest, raid for the rest" do
      navarch = %{army_raid: 120.0, army_invasion: 45.0}

      assert Sortie.attack(:raid, navarch) == 120.0
      assert Sortie.attack(:siege, navarch) == 120.0
      assert Sortie.attack(:conquest, navarch) == 45.0
      assert Sortie.attack(:screen, navarch) == 0.0
      assert Sortie.attack(:raid, %{army_raid: nil}) == 0.0
    end

    test "a fleet sets out while it has lost less than the refit share of its design" do
      assert Sortie.fit?(slots(10), 10, 0.35)
      assert Sortie.fit?(slots(10), 7, 0.35)
      refute Sortie.fit?(slots(10), 6, 0.35)
      refute Sortie.fit?(slots(10), 0, 0.35)
      refute Sortie.fit?(slots(10), nil, 0.35)
    end
  end

  describe "what may be struck" do
    test "an invasion needs troops and a sector the Rebellion owns or borders; a raid only needs strength" do
      assert Sortie.legal?(:raid, 80.0, false)
      assert Sortie.legal?(:siege, 80.0, false)
      assert Sortie.legal?(:conquest, 30.0, true)
      refute Sortie.legal?(:conquest, 30.0, false)
      # A troopless fleet cannot invade, and a fleet with no raid strength cannot pillage.
      refute Sortie.legal?(:conquest, 0.0, true)
      refute Sortie.legal?(:raid, 0.0, false)
      refute Sortie.legal?(:screen, 80.0, true)
    end

    test "a player's last system is not invaded; its dominions and its other systems may be" do
      systems = [
        %{id: 1, status: :inhabited_player, owner: "Ada"},
        %{id: 2, status: :inhabited_dominion, owner: "Ada"},
        %{id: 3, status: :inhabited_player, owner: "Bo"},
        %{id: 4, status: :inhabited_player, owner: "Bo"},
        %{id: 5, status: :inhabited_neutral, owner: nil}
      ]

      holdings = Sortie.holdings(systems)
      assert holdings == %{"Ada" => 1, "Bo" => 2}

      [last, dominion, one_of_two | _] = systems
      assert Sortie.spared?(:conquest, last, holdings)
      refute Sortie.spared?(:conquest, dominion, holdings)
      refute Sortie.spared?(:conquest, one_of_two, holdings)
      # Pillage and bombardment take nothing away, so they spare nobody.
      refute Sortie.spared?(:raid, last, holdings)
      refute Sortie.spared?(:siege, last, holdings)
      # With the knob off there are no holdings to judge by, and nobody is spared.
      refute Sortie.spared?(:conquest, last, nil)
    end

    test "odds are the engine's roll of strength against defense, and unknown when the defense is not legible" do
      assert Sortie.chance(100.0, 5, nil) == nil
      assert Sortie.chance(100.0, 5, 0.0) == 1.0
      assert Sortie.chance(100.0, 5, 100.0) == Wave.Intel.success_chance(100.0, 5, 100.0)
      assert Sortie.chance(10.0, 1, 400.0) == 0.0
      assert Sortie.chance(100.0, nil, 100.0) == Wave.Intel.success_chance(100.0, 1, 100.0)
    end

    test "a garrison the fleet can see and cannot match sends it elsewhere" do
      assert Sortie.outgunned?(10, 14)
      refute Sortie.outgunned?(10, 10)
      refute Sortie.outgunned?(18, 14)
      refute Sortie.outgunned?(10, 0)
    end
  end

  describe "where it goes" do
    defp target(id, opts), do: Map.merge(%{id: id, population: nil, depth: 1, travel: 0.0}, Map.new(opts))

    defp shares(targets) do
      rolls = for n <- 0..999, do: n / 1000
      drawn = Enum.frequencies_by(rolls, &Sortie.pick(targets, &1, rear_factor: 0.5, reach: 1440.0).id)
      Map.new(targets, &{&1.id, Map.get(drawn, &1.id, 0) / 1000})
    end

    test "bigger systems, nearer ones and the front draw more" do
      opts = [nearest_depth: 1, rear_factor: 0.5, reach: 1440.0]

      assert Sortie.weight(target(1, population: 0), opts) == 1.0
      assert Sortie.weight(target(1, population: 100), opts) == 2.0
      assert Sortie.weight(target(1, []), opts) == 1.5
      assert Sortie.weight(target(1, depth: 2), opts) == 0.75
      assert Sortie.weight(target(1, travel: 1440.0), opts) == 0.75
    end

    test "equal systems share the sorties, and the sector behind the front takes its smaller part" do
      assert shares([target(1, []), target(2, [])]) == %{1 => 0.5, 2 => 0.5}

      shares = shares([target(1, depth: 2), target(2, depth: 2), target(3, depth: 3), target(4, depth: 3)])
      assert_in_delta shares[1] + shares[2], 2 / 3, 0.002
      assert_in_delta shares[3] + shares[4], 1 / 3, 0.002
    end

    test "nothing in reach is no target" do
      assert Sortie.pick([], 0.3) == nil
      assert Sortie.pick([target(9, [])], 0.999).id == 9
    end
  end

  describe "the roster" do
    test "a fleet that sets out leaves its post's books and comes back to them when the sortie closes" do
      state =
        warlord()
        |> fleet(1, :siege)
        |> Warlord.advance(10.0)
        |> Warlord.sortie_ordered(1, %{action: "raid", target: 40, from: 600, odds: 0.8})

      entry = Warlord.fleets(state)[1]
      assert entry.stage == :sortie
      assert entry.post == 600
      assert entry.sortie.target == 40
      assert Sortie.targets(Warlord.fleets(state)) == MapSet.new([40])

      state = state |> Warlord.advance(300.0) |> Warlord.sortie_result(1, :fight, :victorious)
      state = Warlord.sortie_result(state, 1, :raid, :normal_success)
      {state, payload} = Warlord.sortie_closed(state, 1)

      assert payload.action == "raid"
      assert payload.target == 40
      assert payload.odds == 0.8
      assert payload.total_ut == 300.0
      assert payload.results == [%{kind: :fight, result: :victorious}, %{kind: :raid, result: :normal_success}]

      entry = Warlord.fleets(state)[1]
      assert entry.stage == :posted
      assert entry.sortie == nil
      assert entry.post == 600

      # It leaves the system it has just struck alone for a while, and only that one.
      assert Sortie.struck?(entry, 40, state.elapsed, 240.0)
      refute Sortie.struck?(entry, 41, state.elapsed, 240.0)
      refute Sortie.struck?(entry, 40, state.elapsed + 240.0, 240.0)
      refute Sortie.struck?(%{role: :raid}, 40, 0.0, 240.0)
      assert Sortie.targets(Warlord.fleets(state)) == MapSet.new()
      assert is_binary(Jason.encode!(Warlord.summary(state)))
    end

    test "a result for a fleet that is on no sortie, and closing one, change nothing" do
      state = fleet(warlord(), 1, :raid)

      assert Warlord.sortie_result(state, 1, :loot, :normal_success) == state
      assert Warlord.sortie_closed(state, 1) == {state, nil}
      assert Warlord.sortie_closed(state, 99) == {state, nil}
    end

    test "a screen's sortie lasts as long as the fleet it covers is on the one they set out on" do
      state =
        warlord()
        |> fleet(1, :siege)
        |> fleet(2, :screen)
        |> Warlord.sortie_ordered(1, %{action: "raid", target: 40, from: 600})
        |> Warlord.sortie_ordered(2, %{action: "escort", target: 40, from: 600, escort_of: 1})

      fleets = Warlord.fleets(state)
      # The screen does not hold the target: the engine's one-siege rule is about strikers.
      assert Sortie.targets(fleets) == MapSet.new([40])
      assert Sortie.escorts(fleets, 1) == [2]
      # Idle at the target, the striker has finished and the screen has only arrived.
      assert Sortie.finished?(fleets[1], fleets)
      refute Sortie.finished?(fleets[2], fleets)

      {state, _payload} = Warlord.sortie_closed(state, 1)
      assert Sortie.finished?(Warlord.fleets(state)[2], Warlord.fleets(state))

      # Only the striker struck the system: a released screen remembers nothing.
      {released, _payload} = Warlord.sortie_closed(state, 2)
      assert Warlord.fleets(released)[2].struck == nil

      # The striker set out again for somewhere else, or was lost: the screen is released either way.
      again = Warlord.sortie_ordered(state, 1, %{action: "raid", target: 41, from: 40})
      assert Sortie.finished?(Warlord.fleets(again)[2], Warlord.fleets(again))

      lost = Warlord.forget_fleet(state, 1)
      assert Sortie.finished?(Warlord.fleets(lost)[2], Warlord.fleets(lost))
    end

    test "a fleet's strike counts as pressure on the system it lands in" do
      assert Wave.Pressure.weight("loot") == 1.0
      assert Wave.Pressure.weight("raid") == 1.0
      assert Wave.Pressure.weight("conquest") == 1.0
      assert Wave.Pressure.weight("escort") == 0.0
    end
  end
end
