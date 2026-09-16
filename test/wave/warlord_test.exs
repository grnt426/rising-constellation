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

  describe "work in flight" do
    test "dispatched colonisers and targeted Siderians count against their sectors" do
      state =
        warlord()
        |> Warlord.track(1)
        |> Warlord.dispatched(1, 20)
        |> Warlord.track(2)
        |> Warlord.track_siderian(5)
        |> Warlord.siderian_dispatched(5, 21)
        |> Warlord.track_siderian(6)
        |> Warlord.siderian_dispatched(6, 40)
        |> Warlord.track_siderian(7)

      assert Warlord.pending_by_sector(state, %{20 => 2, 21 => 2, 40 => 4}) == %{2 => 2, 4 => 1}
    end
  end

  describe "sector pace" do
    test "the allowance reads the share curve a lead day ahead, scaled to the map" do
      assert Warlord.sector_allowance(warlord(), 19) == 1
      assert warlord() |> Warlord.advance(480.0 * 8.5) |> Warlord.sector_allowance(19) == 6
      assert warlord() |> Warlord.advance(480.0 * 40) |> Warlord.sector_allowance(19) == 13
    end

    test "the shipped share curve never shrinks" do
      curve = Wave.defaults()["sector_share_by_day"]
      assert [_ | _] = curve
      assert curve == Enum.scan(curve, &max/2)
    end
  end

  describe "agent ceilings" do
    test "a per-player curve holds its last value" do
      assert Warlord.curve_value([0.5, 1.0, 2.5], 1) == 0.5
      assert Warlord.curve_value([0.5, 1.0, 2.5], 3) == 2.5
      assert Warlord.curve_value([0.5, 1.0, 2.5], 30) == 2.5
      assert Warlord.curve_value([0.5, 1.0, 2.5], 0) == 0.5
      assert Warlord.curve_value([], 5) == 0.0
    end

    test "scale to the players, rounded, and never below one" do
      assert Warlord.scaled_ceiling(1.0, 15) == 15
      assert Warlord.scaled_ceiling(0.88, 15) == 13
      assert Warlord.scaled_ceiling(0.0, 15) == 1
      assert Warlord.scaled_ceiling(2.5, 1) == 3
    end

    test "follow the live human count, never below scale_players_min" do
      state = warlord()
      assert Warlord.scale_players(state) == 1
      assert Warlord.scale_players(Warlord.gauge(state, :human_players, 16)) == 16
    end

    test "read the shipped curves by match day and human count" do
      state = warlord() |> Warlord.gauge(:human_players, 15) |> Warlord.advance(480.0 * 6)
      curve = Wave.defaults()["siderians_per_player_by_day"]

      assert Warlord.match_day(state) == 7
      assert Warlord.agent_ceiling(state, :siderians) == Warlord.scaled_ceiling(Warlord.curve_value(curve, 7), 15)
      assert state |> Warlord.ceilings() |> Map.keys() |> Enum.sort() == [:erased, :navarchs, :siderians]
    end

    test "the shipped curves never shrink" do
      for key <- ~w(siderians_per_player_by_day navarchs_per_player_by_day erased_per_player_by_day) do
        curve = Wave.defaults()[key]
        assert [_ | _] = curve
        assert curve == Enum.scan(curve, &max/2)
      end
    end
  end

  describe "Siderian target spreading" do
    test "a target with n Siderians committed is admitted at falloff^n" do
      candidates = [%{id: 1}, %{id: 2}, %{id: 3}]
      commitments = %{2 => 1, 3 => 3}

      assert ids(Warlord.admit_targets(candidates, commitments, 0.5, 0.2)) == [1]
      assert ids(Warlord.admit_targets(candidates, commitments, 0.1, 0.2)) == [1, 2]
      assert ids(Warlord.admit_targets(candidates, commitments, 0.001, 0.2)) == [1, 2, 3]
    end

    test "with every target committed, the least-committed ones stay available" do
      assert ids(Warlord.admit_targets([%{id: 2}, %{id: 3}], %{2 => 1, 3 => 3}, 0.9, 0.2)) == [2]
      assert Warlord.admit_targets([], %{}, 0.5, 0.2) == []
    end

    test "commitments count dispatched Siderians, leaving out the one being sent" do
      state =
        warlord()
        |> Warlord.track_siderian(5)
        |> Warlord.track_siderian(6)
        |> Warlord.track_siderian(7)
        |> Warlord.siderian_dispatched(5, 40)
        |> Warlord.siderian_dispatched(6, 40)
        |> Warlord.siderian_dispatched(7, 41)

      assert Warlord.commitments(state) == %{40 => 2, 41 => 1}
      assert Warlord.commitments(state, 5) == %{40 => 1, 41 => 1}
    end
  end

  describe "Siderian telemetry" do
    test "buckets an observed state" do
      assert Warlord.siderian_bucket(:moving, false) == :moving
      assert Warlord.siderian_bucket(:docking, true) == :moving
      assert Warlord.siderian_bucket(:make_dominion, true) == :acting
      assert Warlord.siderian_bucket(:encourage_hate, false) == :acting
      assert Warlord.siderian_bucket(:idle, true) == :resting
      assert Warlord.siderian_bucket(:idle, false) == :idle
      assert Warlord.siderian_bucket(nil, false) == :other
    end

    test "game time goes to the state seen at the previous observation" do
      state = Warlord.track_siderian(warlord(), 5)
      {state, []} = Warlord.observe_siderian(state, 5, :idle, :idle)
      state = Warlord.advance(state, 3.0)
      {state, []} = Warlord.observe_siderian(state, 5, :moving, :moving)
      state = Warlord.advance(state, 10.0)
      {state, []} = Warlord.observe_siderian(state, 5, :moving, :moving)

      assert state.siderians[5].time == %{idle: 3.0, moving: 10.0}
      assert state.telemetry.siderian_ut == %{idle: 3.0, moving: 10.0}
    end

    test "an attempt starts when its action is seen, then is scored with travel and action time" do
      state = warlord() |> Warlord.track_siderian(5) |> Warlord.siderian_dispatched(5, 40, %{hops: 3, overlap: 1})
      {state, []} = Warlord.observe_siderian(state, 5, :moving, :moving)

      state = Warlord.advance(state, 20.0)
      {state, [{:started, 5, started}]} = Warlord.observe_siderian(state, 5, :acting, :make_dominion)
      assert started.travel_ut == 20.0
      assert state.stats.capture_started == 1

      state = Warlord.advance(state, 150.0)
      {state, resolved} = Warlord.resolve_siderian(state, 5, false)

      assert resolved.outcome == :failed
      assert resolved.travel_ut == 20.0
      assert resolved.action_ut == 150.0
      assert resolved.hops == 3 and resolved.overlap == 1
      assert state.stats.capture_failed == 1
      assert state.siderians[5].stage == :idle
      assert Warlord.commitments(state) == %{}
      assert Warlord.summary(state).telemetry.avg_action_ut == 150.0
    end

    test "an attempt that never started is aborted; a turned system is captured" do
      state = warlord() |> Warlord.track_siderian(5) |> Warlord.siderian_dispatched(5, 40)
      {state, aborted} = Warlord.resolve_siderian(Warlord.advance(state, 5.0), 5, false)

      assert aborted.outcome == :aborted
      assert aborted.action_ut == nil
      assert state.stats.capture_aborted == 1

      {state, captured} = state |> Warlord.siderian_dispatched(5, 41) |> Warlord.resolve_siderian(5, true)
      assert captured.outcome == :captured
      assert state.stats.captured == 1
    end

    test "one daily rollup per match day" do
      state = warlord()
      assert Warlord.daily_report_due?(state)

      state = Warlord.mark_daily_reported(state)
      refute Warlord.daily_report_due?(state)

      state = Warlord.advance(state, 480.0)
      assert Warlord.daily_report_due?(state)
      assert is_binary(Jason.encode!(Warlord.daily_payload(state, %{systems: 12})))
    end
  end

  describe "Siderian hiring" do
    test "capture strength counts only skill points that grant make_dominion" do
      specializations = [
        %{index: 0, bonus: [%Core.Bonus{from: :direct, value: 10, type: :add, to: :speaker_make_dominion}]},
        %{index: 4, bonus: [%Core.Bonus{from: :sys_technology, value: 0.05, type: :mul, to: :sys_technology}]}
      ]

      assert Warlord.capture_strength([0, 0, 0, 0, 1, 0], specializations) == 0
      assert Warlord.capture_strength([2, 0, 0, 0, 1, 0], specializations) == 20
      assert Warlord.capture_strength(nil, specializations) == 0
    end

    test "the shipped speaker table puts capture strength on the proselyte skill alone" do
      speaker = Enum.find(Data.Game.Character.Content.data(), &(&1.key == :speaker))

      assert Warlord.capture_strength([1, 0, 0, 0, 0, 0], speaker.specializations) > 0
      assert Warlord.capture_strength([0, 1, 1, 1, 1, 1], speaker.specializations) == 0
    end

    test "without a score it buys the cheapest of the preferred rank, else of any rank" do
      by_rank = %{
        common: [market_character(1, credit: 900), market_character(2, credit: 500)],
        rare: [market_character(3, credit: 100)]
      }

      assert {:ok, %{id: 2}} = Warlord.pick_candidate(by_rank, :common)
      assert {:ok, %{id: 3}} = Warlord.pick_candidate(%{by_rank | common: []}, :common)
      assert Warlord.pick_candidate(%{}, :common) == {:error, :no_candidate}
    end

    test "with a score it never buys a zero, prefers the strongest, then the cheapest" do
      strength = &Enum.at(&1.skills, 0)
      scholar = market_character(1, skills: [0, 0, 0, 0, 1, 0])

      by_rank = %{
        common: [
          scholar,
          market_character(2, skills: [1, 0, 0, 0, 0, 0], ideology: 300),
          market_character(3, skills: [1, 0, 0, 0, 0, 0], ideology: 200)
        ],
        rare: [market_character(4, skills: [3, 0, 0, 0, 0, 0])]
      }

      assert {:ok, %{id: 3}} = Warlord.pick_candidate(by_rank, :common, strength)
      assert {:ok, %{id: 4}} = Warlord.pick_candidate(%{by_rank | common: [scholar]}, :common, strength)
      assert Warlord.pick_candidate(%{common: [scholar]}, :common, strength) == {:error, :no_candidate}
    end

    test "a market with nobody capable defers the next look instead of retrying every pass" do
      empty = Warlord.defer_siderian_hire(warlord())
      refute Warlord.siderian_hire_due?(empty)
      assert empty |> Warlord.advance(10.0) |> Warlord.siderian_hire_due?()

      staffed = warlord() |> Warlord.track_siderian(5) |> Warlord.advance(300.0)
      assert Warlord.siderian_hire_due?(staffed)

      staffed = Warlord.defer_siderian_hire(staffed)
      refute Warlord.siderian_hire_due?(staffed)
      assert staffed |> Warlord.advance(10.0) |> Warlord.siderian_hire_due?()
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
    test "a Warlord saved before the Siderian and telemetry fields existed upgrades and keeps running" do
      old = Map.drop(warlord(), [:siderians, :siderian_accum, :passes, :gauges, :perf, :telemetry])
      refute Map.has_key?(old, :siderians)

      state = old |> Warlord.advance(5.0) |> Warlord.track_siderian(9)
      {state, []} = Warlord.observe_siderian(state, 9, :idle, :idle)

      assert state.siderians |> Map.keys() == [9]
      assert state.hire_accum == 5.0
      assert is_binary(Jason.encode!(Warlord.summary(old)))
    end

    test "a roster entry from before telemetry is observed and scored without crashing" do
      state = %{warlord() | siderians: %{9 => %{stage: :dispatched, target: 40, since: 0.0}}}
      state = Warlord.advance(state, 4.0)

      {state, []} = Warlord.observe_siderian(state, 9, :moving, :moving)
      {_state, payload} = Warlord.resolve_siderian(state, 9, false)

      assert payload.outcome == :aborted
      assert payload.total_ut == 4.0
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

  defp ids(candidates), do: candidates |> Enum.map(& &1.id) |> Enum.sort()

  defp market_character(id, opts) do
    %{
      id: id,
      skills: Keyword.get(opts, :skills, [0, 0, 0, 0, 0, 0]),
      credit_cost: Keyword.get(opts, :credit, 0),
      technology_cost: 0,
      ideology_cost: Keyword.get(opts, :ideology, 0)
    }
  end
end
