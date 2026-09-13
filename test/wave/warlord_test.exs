defmodule Wave.WarlordTest do
  use ExUnit.Case, async: true

  alias Wave.Warlord

  # Sectors (adjacency in brackets):
  #   1 rebellion [2]   2 unowned [1, 3]   3 tetrarchy [2, 4]   4 unowned [3]
  # Rebellion may expand into 1 (its own) and 2 (adjacent); not 3 or 4.
  #
  # Lanes: 10—11, 10—20, 20—21, 20—30, 30—40
  @galaxy %{
    sectors: [
      %{id: 1, owner: :rebellion, adjacent: [2]},
      %{id: 2, owner: nil, adjacent: [1, 3]},
      %{id: 3, owner: :tetrarchy, adjacent: [2, 4]},
      %{id: 4, owner: nil, adjacent: [3]}
    ],
    stellar_systems: [
      %{id: 10, sector_id: 1, status: :inhabited_player},
      %{id: 11, sector_id: 1, status: :uninhabited},
      %{id: 20, sector_id: 2, status: :uninhabited},
      %{id: 21, sector_id: 2, status: :inhabited_neutral},
      %{id: 30, sector_id: 3, status: :uninhabited},
      %{id: 40, sector_id: 4, status: :uninhabited}
    ],
    edges: [
      %{s1: %{id: 10}, s2: %{id: 11}},
      %{s1: %{id: 10}, s2: %{id: 20}},
      %{s1: %{id: 20}, s2: %{id: 21}},
      %{s1: %{id: 20}, s2: %{id: 30}},
      %{s1: %{id: 30}, s2: %{id: 40}}
    ]
  }

  # An instance id with no metadata registered: Wave.Config falls back to the
  # shipped defaults, which is what these pure tests want.
  defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

  describe "targeting" do
    test "takeable sectors are the owned ones plus their neighbours" do
      assert Warlord.takeable_sector_ids(@galaxy, :rebellion) == MapSet.new([1, 2])
      assert Warlord.takeable_sector_ids(@galaxy, :tetrarchy) == MapSet.new([2, 3, 4])
    end

    test "picks the nearest uninhabited takeable system, breaking hop ties by id" do
      assert %{id: 11} = Warlord.colonisation_target(@galaxy, :rebellion, 10, MapSet.new())
    end

    test "skips reserved targets" do
      assert %{id: 20} = Warlord.colonisation_target(@galaxy, :rebellion, 10, MapSet.new([11]))
    end

    test "never targets inhabited systems or sectors out of reach" do
      # 21 is neutral, 30 sits in a tetrarchy sector, 40 is not adjacent to rebel space
      assert Warlord.colonisation_target(@galaxy, :rebellion, 10, MapSet.new([11, 20])) == nil
    end

    test "a Navarch in transit has no target" do
      assert Warlord.colonisation_target(@galaxy, :rebellion, nil, MapSet.new()) == nil
    end

    test "the itinerary is one jump per lane, then the colonisation" do
      assert Warlord.colonisation_actions([{10, 20}, {20, 30}], 30) == [
               %{"type" => "jump", "data" => %{"source" => 10, "target" => 20}},
               %{"type" => "jump", "data" => %{"source" => 20, "target" => 30}},
               %{"type" => "colonization", "data" => %{"target" => 30}}
             ]
    end
  end

  describe "hire clock" do
    test "is due once a full interval has accumulated, keeping the overshoot" do
      state = warlord()
      refute Warlord.hire_due?(state)

      state = Warlord.advance(state, 130.0)
      assert Warlord.hire_due?(state)

      state = Warlord.consume_hire(state)
      assert state.hire_accum == 10.0
      refute Warlord.hire_due?(state)
    end

    test "the tick interval never exceeds the time to the next hire" do
      state = Warlord.advance(warlord(), 119.5)
      assert Warlord.compute_next_tick_interval(state) == 0.5
      assert Warlord.compute_next_tick_interval(warlord()) == 1.0
    end
  end

  describe "coloniser bookkeeping" do
    test "reserved targets follow dispatch and release" do
      state =
        warlord()
        |> Warlord.track(1)
        |> Warlord.track(2)
        |> Warlord.dispatched(1, 20)

      assert Warlord.reserved_targets(state) == MapSet.new([20])
      assert Warlord.active_coloniser_count(state) == 2

      state = Warlord.released(state, 1)
      assert Warlord.reserved_targets(state) == MapSet.new()

      state = Warlord.forget(state, 2)
      assert Warlord.active_coloniser_count(state) == 1
    end

    test "counts and refusals accumulate and the summary encodes to JSON" do
      state =
        warlord()
        |> Warlord.count(:hired)
        |> Warlord.count(:hired)
        |> Warlord.refuse(:hire, :no_candidate)
        |> Warlord.refuse(:hire, :no_candidate)
        |> Warlord.track(7)

      assert state.stats.hired == 2
      assert state.stats.refused == %{{:hire, :no_candidate} => 2}

      summary = Warlord.summary(state)
      assert summary.stats.refused == %{"hire::no_candidate" => 2}
      assert is_binary(Jason.encode!(summary))
    end
  end
end
