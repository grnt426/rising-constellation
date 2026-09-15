defmodule Wave.WarlordTest do
  use ExUnit.Case, async: true

  alias Wave.Warlord

  # An instance id with no metadata registered: Wave.Config falls back to the
  # shipped defaults, which is what these pure tests want.
  defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

  describe "itinerary" do
    test "is one jump per lane, then the terminal action" do
      assert Warlord.itinerary([{10, 20}, {20, 30}], "make_dominion", 30) == [
               %{"type" => "jump", "data" => %{"source" => 10, "target" => 20}},
               %{"type" => "jump", "data" => %{"source" => 20, "target" => 30}},
               %{"type" => "make_dominion", "data" => %{"target" => 30}}
             ]
    end

    test "is just the action when the agent already stands on the target" do
      assert Warlord.itinerary([], "colonization", 7) == [%{"type" => "colonization", "data" => %{"target" => 7}}]
    end
  end

  describe "Navarch hire clock" do
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

    test "a hire held due at the roster cap keeps the normal cadence instead of spinning" do
      held = %{warlord() | hire_accum: 120.0}
      assert Warlord.hire_due?(held)
      assert Warlord.compute_next_tick_interval(held) == 1.0

      overdue = %{warlord() | hire_accum: 500.0}
      assert Warlord.compute_next_tick_interval(overdue) == 1.0
    end
  end

  describe "coloniser cap" do
    test "is 1.5x the unclaimed neighbourhood, rounded down" do
      assert Warlord.coloniser_cap(0, 1.5, 20) == 0
      assert Warlord.coloniser_cap(1, 1.5, 20) == 1
      assert Warlord.coloniser_cap(3, 1.5, 20) == 4
      assert Warlord.coloniser_cap(4, 1.5, 20) == 6
    end

    test "never exceeds the absolute ceiling" do
      assert Warlord.coloniser_cap(40, 1.5, 20) == 20
    end
  end

  describe "Siderians" do
    test "the first hire is immediate, later ones wait a full interval" do
      state = warlord()
      assert Warlord.siderian_hire_due?(state)

      state = Warlord.track_siderian(state, 5)
      refute Warlord.siderian_hire_due?(state)

      state = Warlord.advance(state, 120.0)
      assert Warlord.siderian_hire_due?(state)
    end

    test "are capped by capture targets and the ceiling" do
      assert Warlord.siderian_cap(0, 3) == 0
      assert Warlord.siderian_cap(2, 3) == 2
      assert Warlord.siderian_cap(9, 3) == 3
    end

    test "capture targets are reserved while an attempt runs" do
      state =
        warlord()
        |> Warlord.track_siderian(5)
        |> Warlord.track_siderian(6)
        |> Warlord.siderian_dispatched(5, 40)

      assert Warlord.siderian_targets(state) == MapSet.new([40])

      state = Warlord.siderian_released(state, 5)
      assert Warlord.siderian_targets(state) == MapSet.new()

      state = Warlord.forget_siderian(state, 6)
      assert Map.keys(state.siderians) == [5]
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
  end

  describe "snapshot tolerance" do
    test "a Warlord saved before the Siderian fields existed upgrades and keeps running" do
      old = Map.drop(warlord(), [:siderians, :siderian_accum, :passes, :gauges, :perf])
      refute Map.has_key?(old, :siderians)

      state = old |> Warlord.advance(5.0) |> Warlord.track_siderian(9)

      assert state.siderians |> Map.keys() == [9]
      assert state.hire_accum == 5.0
      assert is_binary(Jason.encode!(Warlord.summary(old)))
    end
  end

  describe "readout" do
    test "counts, refusals, gauges and pass cost accumulate and encode to JSON" do
      state =
        warlord()
        |> Warlord.count(:hired)
        |> Warlord.count(:hired)
        |> Warlord.refuse(:hire, :no_candidate)
        |> Warlord.refuse(:hire, :no_candidate)
        |> Warlord.gauge(:coloniser_cap, 4)
        |> Warlord.record_pass(1_000, 50)
        |> Warlord.record_pass(3_000, 150)
        |> Warlord.track(7)

      assert state.stats.hired == 2
      assert state.stats.refused == %{{:hire, :no_candidate} => 2}

      summary = Warlord.summary(state)
      assert summary.stats.refused == %{"hire::no_candidate" => 2}
      assert summary.gauges == %{coloniser_cap: 4}
      assert summary.perf.passes == 2
      assert summary.perf.avg_us == 2_000
      assert summary.perf.max_us == 3_000
      assert summary.perf.avg_reductions == 100
      assert is_binary(Jason.encode!(summary))
    end
  end
end
