defmodule Wave.WarlordTest do
  use ExUnit.Case, async: true

  alias Wave.Warlord

  # An instance id with no metadata registered: Wave.Config falls back to the
  # shipped defaults, which is what these pure tests want.
  defp warlord, do: Warlord.new(System.unique_integer([:positive]), :rebellion)

  describe "pass schedule" do
    # Every call to the agent ticks it (the tick decorator), so reads from the
    # diagnostics page or an autosave must advance the clocks without acting.
    test "a read between passes advances the clocks but is not a pass" do
      state = warlord() |> Warlord.mark_pass()
      assert state.next_pass_in == 1.0

      read = Warlord.advance(state, 0.25)
      refute Warlord.pass_due?(read)
      assert Warlord.compute_next_tick_interval(read) == 0.75
      assert read.hire_accum == 0.25

      assert Warlord.pass_due?(Warlord.advance(read, 0.72))
    end

    test "a fresh or restored-from-old-snapshot Warlord passes at once, and force_pass overrides the schedule" do
      assert Warlord.pass_due?(warlord())
      assert Warlord.pass_due?(Warlord.upgrade(Map.drop(warlord(), [:since_pass, :next_pass_in])))
      assert warlord() |> Warlord.mark_pass() |> Warlord.force_pass() |> Warlord.pass_due?()
    end
  end

  describe "construction allowance" do
    test "the bot gets its starting credit once, then only the floor" do
      fresh = warlord()
      assert Warlord.credit_target(fresh) == {Wave.defaults()["starting_credit"], :grant}

      granted = Warlord.mark_granted(fresh, 10_000_000)
      assert Warlord.credit_target(granted) == {Wave.defaults()["credit_floor"], :floor}

      # restored from a snapshot taken before the grant existed: its start
      # money came from the old floor
      old = fresh |> Map.drop([:construction]) |> Map.put(:passes, 12)
      assert Warlord.credit_target(old) == {Wave.defaults()["credit_floor"], :floor}
    end

    test "is what was left plus a share of the income, within the credit above the floor" do
      assert Warlord.construction_allowance(100, 50, 2, 0.8, 1_000_000, 1_000) == 180.0
      # nothing accrues from a deficit
      assert Warlord.construction_allowance(100, -50, 2, 0.8, 1_000_000, 1_000) == 100
      # never above the credit over the floor, never below zero
      assert Warlord.construction_allowance(5_000, 50, 2, 0.8, 3_000, 1_000) == 2_000
      assert Warlord.construction_allowance(5_000, 50, 2, 0.8, 500, 1_000) == 0
    end

    test "splits the starting credit like income, then adds the share of what was earned since" do
      state = warlord()
      on_exit(fn -> Wave.Budget.clear(state.instance_id) end)
      share = Wave.defaults()["construction_income_share"]

      state = state |> Warlord.mark_granted(10_000_000) |> Warlord.update_construction(10_000_000, 2_000)
      assert Wave.Budget.available(state.instance_id) == trunc(share * 10_000_000)
      refute Map.has_key?(state.construction, :grant)

      # the systems spend 5M; ten ut later the pass adds the share of 10 ut of income
      :ok = Wave.Budget.take(state.instance_id, 5_000_000)
      state = state |> Warlord.advance(10.0) |> Warlord.update_construction(6_000_000, 2_000)

      assert Wave.Budget.available(state.instance_id) ==
               trunc(share * 10_000_000) - 5_000_000 + trunc(share * 2_000 * 10)

      assert trunc(state.construction.allowance) == Wave.Budget.available(state.instance_id)

      # the table lost its row (a restart): the pass carries on from what it last set
      Wave.Budget.clear(state.instance_id)
      before = trunc(state.construction.allowance)
      state = Warlord.update_construction(state, 6_000_000, 2_000)
      assert Wave.Budget.available(state.instance_id) == before
      assert Warlord.summary(state).construction.allowance == before
    end
  end

  describe "order ledger" do
    test "counts taken and refused requests per kind, with the refusal reasons" do
      state =
        warlord()
        |> Warlord.advance(3.0)
        |> Warlord.order("order:make_dominion", :ok)
        |> Warlord.order("order:make_dominion", {:error, :no_route})
        |> Warlord.order("order:make_dominion", {:error, :no_route})
        |> Warlord.order("hire:siderian", {:error, {:market, :no_candidate}})

      assert %{ok: 1, failed: 2, reasons: %{"no_route" => 2}, last_reason: "no_route", last_failed_ut: 3.0} =
               state.orders["order:make_dominion"]

      assert %{ok: 0, failed: 1, reasons: %{"market:no_candidate" => 1}} = state.orders["hire:siderian"]
      assert Warlord.summary(state).orders == state.orders
    end

    test "refusal reasons stop taking new keys after 40, so a long match can't grow the snapshot" do
      state =
        Enum.reduce(1..60, warlord(), fn n, acc ->
          acc
          |> Warlord.order("order:colonization", {:error, {:unexpected, n}})
          |> Warlord.refuse(:dispatch, {:unexpected, n})
        end)

      reasons = state.orders["order:colonization"].reasons
      assert map_size(reasons) == 41
      assert reasons["other"] == 20
      assert map_size(state.stats.refused) == 41
      assert state.stats.refused[{:dispatch, :other}] == 20
    end

    test "a snapshot from before the ledger restores with an empty one" do
      old = Map.delete(warlord(), :orders)
      assert Warlord.upgrade(old).orders == %{}
    end
  end

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

    test "without a score it buys the cheapest of the first rank that has anyone" do
      by_rank = %{
        common: [market_character(1, credit: 900), market_character(2, credit: 500)],
        remarkable: [market_character(3, credit: 100)]
      }

      assert {:ok, %{id: 2}, :common} = Warlord.pick_candidate(by_rank, [:common])
      assert {:ok, %{id: 2}, :common} = Warlord.pick_candidate(by_rank, [:common, :remarkable])
      assert {:ok, %{id: 3}, :remarkable} = Warlord.pick_candidate(by_rank, [:remarkable, :common])

      assert {:ok, %{id: 3}, :remarkable} =
               Warlord.pick_candidate(%{remarkable: by_rank.remarkable}, [:common, :remarkable])

      assert Warlord.pick_candidate(%{}, [:common]) == {:error, :no_candidate}
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
        remarkable: [market_character(4, skills: [3, 0, 0, 0, 0, 0])]
      }

      assert {:ok, %{id: 3}, :common} = Warlord.pick_candidate(by_rank, [:common], strength)
      # A stronger agent at a rank further down the order does not jump the queue.
      assert {:ok, %{id: 3}, :common} = Warlord.pick_candidate(by_rank, [:common, :remarkable], strength)
      assert {:ok, %{id: 4}, :remarkable} = Warlord.pick_candidate(by_rank, [:remarkable, :common], strength)
      assert Warlord.pick_candidate(%{common: [scholar]}, [:common], strength) == {:error, :no_candidate}
      # A rank with nobody able falls through to the next.
      assert {:ok, %{id: 4}, :remarkable} =
               Warlord.pick_candidate(
                 %{common: [scholar], remarkable: by_rank.remarkable},
                 [:common, :remarkable],
                 strength
               )
    end

    test "a hire with several roles tries every role at a rank before the next rank" do
      capture = &Enum.at(&1.skills, 0)
      destab = &Enum.at(&1.skills, 1)
      agitator = market_character(1, skills: [0, 1, 0, 0, 0, 0])
      proselyte = market_character(2, skills: [4, 0, 0, 0, 0, 0])
      by_rank = %{common: [agitator], remarkable: [proselyte]}
      roles = [capture: capture, destab: destab]

      # Capture is the more urgent role, but the common rank keeps the hire:
      # its agitator is bought for the next role rather than a remarkable proselyte.
      assert {:ok, %{id: 1}, :common, :destab} = Warlord.pick_for_roles(by_rank, [:common, :remarkable], roles)
      assert {:ok, %{id: 2}, :remarkable, :capture} = Warlord.pick_for_roles(by_rank, [:remarkable, :common], roles)

      assert {:ok, %{id: 2}, :remarkable, :capture} =
               Warlord.pick_for_roles(by_rank, [:common, :remarkable], capture: capture)

      assert Warlord.pick_for_roles(by_rank, [:common], capture: capture) == {:error, :no_candidate}
      assert Warlord.pick_for_roles(by_rank, [:common, :remarkable], []) == {:error, :no_candidate}
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

  describe "pass steps" do
    # i185, 2026-10-15..20: the hostile reading raised on every pass, the whole
    # pass was thrown away each time, and the Rebellion stood still for days.
    test "a step that raises is skipped and the steps around it keep their work" do
      raising = fn state ->
        state |> Warlord.count(:half_done) |> then(fn _ -> raise ArgumentError, "boom" end)
      end

      state = warlord() |> Warlord.advance(7.0)
      {state, nil} = Warlord.run_step(state, "drop_departed", &Warlord.count(&1, :hired), & &1)
      {state, failure} = Warlord.run_step(state, "recon", raising, & &1)
      {state, nil} = Warlord.run_step(state, "research", &Warlord.count(&1, :dismissed), & &1)

      assert state.stats.hired == 1
      assert state.stats.dismissed == 1
      # The failed step's own partial work is gone with it.
      refute Map.has_key?(state.stats, :half_done)

      assert %{error: %ArgumentError{message: "boom"}, streak: 1, log?: true} = failure

      assert %{failed: 1, streak: 1, last_failed_ut: 7.0, last_error: "ArgumentError: boom at " <> _} =
               state.step_failures["recon"]

      refute Map.has_key?(state.step_failures, "drop_departed")
    end

    test "a step that returns a pair falls back to the pair its caller expects" do
      state = warlord() |> Warlord.advance(4.0)

      {{state, view}, %{streak: 1}} =
        Warlord.run_step(state, "recon", fn _ -> raise KeyError, key: :owner end, &{Warlord.mark_recon(&1), nil})

      assert view == nil
      # A failed reading still counts as taken, so it is retried an interval later.
      assert state.erased_recon_at == 4.0
      refute Warlord.recon_due?(state, 3.0)

      {{_state, :read}, nil} = Warlord.run_step(state, "recon", &{&1, :read}, &{&1, nil})
    end

    test "a streak logs at its start, on a new error and every 100th repeat, and ends on a clean run" do
      fail = &Warlord.step_failed(&1, "recon", &2)

      {state, logged} =
        Enum.reduce(1..250, {warlord(), 0}, fn _, {state, logged} ->
          {state, log?} = fail.(state, "E1")
          {state, if(log?, do: logged + 1, else: logged)}
        end)

      # Passes 1, 100 and 200.
      assert logged == 3
      assert Warlord.failure_streak(state, "recon") == 250

      {state, true} = fail.(state, "E2")
      {state, false} = fail.(state, "E2")
      assert Warlord.failing_steps(state, 3) == ["recon"]

      state = state |> Warlord.advance(2.0) |> Warlord.step_ok("recon")
      assert %{failed: 252, streak: 0, recovered_ut: 2.0, last_error: "E2"} = state.step_failures["recon"]
      assert Warlord.failing_steps(state, 1) == []

      {_state, true} = fail.(state, "E2")
    end

    test "errors are kept short, and the ledger encodes and restores" do
      {state, true} = Warlord.step_failed(warlord(), "steer_fleets", String.duplicate("x", 1_000))
      assert String.length(state.step_failures["steer_fleets"].last_error) == 300

      assert Warlord.summary(state).step_failures == state.step_failures
      assert is_binary(Jason.encode!(Warlord.summary(state)))
      assert Warlord.upgrade(Map.delete(warlord(), :step_failures)).step_failures == %{}
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

    test "a snapshot taken before the Erased existed restores with an empty roster" do
      old = Map.drop(warlord(), [:erased, :erased_accum, :erased_recon_at])
      refute Map.has_key?(old, :erased)

      restored = Warlord.upgrade(old)

      assert restored.erased == %{}
      assert restored.erased_accum == 0.0
      assert restored.erased_recon_at == nil
      assert Warlord.erased_hire_due?(restored)
      assert Warlord.recon_due?(restored, 3.0)
    end

    test "a snapshot taken before the rank mix restores with no hires counted" do
      old = Map.drop(warlord(), [:hire_ranks])

      restored = Warlord.upgrade(old)

      assert restored.hire_ranks == %{}
      assert Warlord.rank_order(Map.drop(warlord(), [:hire_ranks]), :erased) == [:common, :remarkable]

      assert restored |> Warlord.record_hire_rank(:erased, :common) |> Map.fetch!(:hire_ranks) ==
               %{erased: %{from: 0, counts: %{common: 1}}}
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

  describe "pressure on a system" do
    test "orders stack, wear off one per fade, and the readout lists what still stands" do
      state =
        warlord()
        |> Warlord.press(103, 1.0)
        |> Warlord.press(103, 1.0)
        |> Warlord.press(106, 0.5)

      assert Warlord.pressure(state, 103) == 2.0
      assert Warlord.pressure(state, 106) == 0.5
      assert Warlord.pressure(state, 999) == 0.0

      # Half a match day (the default `pressure_fade_ut`) wears one stack off.
      later = Warlord.advance(state, 240.0)
      assert Warlord.pressure(later, 103) == 1.0
      assert Warlord.pressure(later, 106) == 0.0
      assert Warlord.summary(later).pressure == %{103 => 1.0}
      assert is_binary(Jason.encode!(Warlord.summary(later)))

      # The next order builds on what is left and drops what has worn off.
      again = Warlord.press(later, 103, 1.0)
      assert Warlord.pressure(again, 103) == 2.0
      assert Map.keys(again.pressure) == [103]
    end

    test "an order that weighs nothing books nothing" do
      assert Warlord.press(warlord(), 103, 0.0).pressure == %{}
    end

    test "a snapshot taken before pressure existed restores with nothing booked" do
      old = Map.drop(warlord(), [:pressure])

      assert Warlord.pressure(old, 103) == 0.0
      assert Warlord.pressure(Warlord.press(old, 103, 1.0), 103) == 1.0
      assert Warlord.upgrade(old).pressure == %{}
      assert Warlord.summary(old).pressure == %{}
    end
  end

  describe "stuck orders" do
    test "an agent on an order is counted each pass the engine shows it idle, and cleared when it moves" do
      state =
        warlord()
        |> Warlord.track(7)
        |> Warlord.dispatched(7, 40)
        |> Warlord.track_siderian(8)
        |> Warlord.siderian_dispatched(8, 41)
        |> Warlord.track_erased(9, %{theatre: :field, duty: :removal})
        |> Warlord.erased_dispatched(9, 42, %{action: "infiltrate"})

      idle = MapSet.new([7, 8, 9])
      state = state |> Warlord.mark_stuck(idle) |> Warlord.mark_stuck(idle)

      assert Warlord.stuck_passes(state.colonisers[7]) == 2
      assert Warlord.stuck_passes(state.siderians[8]) == 2
      assert Warlord.stuck_passes(state.erased[9]) == 2

      # 8 is under way again; 7 and 9 still show nothing.
      state = Warlord.mark_stuck(state, MapSet.new([7, 9]))

      assert Warlord.stuck_passes(state.colonisers[7]) == 3
      assert Warlord.stuck_passes(state.siderians[8]) == 0
      refute Map.has_key?(state.siderians[8], :stuck)
      assert Warlord.stuck_passes(state.erased[9]) == 3
    end

    test "an agent that is moving or acting is never counted, however long it has been on the order" do
      state =
        warlord()
        |> Warlord.track_siderian(8)
        |> Warlord.siderian_dispatched(8, 41)
        |> Warlord.advance(900.0)
        |> Warlord.mark_stuck(MapSet.new())

      assert Warlord.stuck_passes(state.siderians[8]) == 0
    end

    test "an agent waiting for orders is not on one, so it is never stuck" do
      state = warlord() |> Warlord.track_siderian(8) |> Warlord.mark_stuck(MapSet.new([8]))

      assert Warlord.stuck_passes(state.siderians[8]) == 0
    end

    test "scouting and evading restart the order clock, so the page shows the trip and not the hire" do
      state = warlord() |> Warlord.track_siderian(8, :seduce) |> Warlord.advance(500.0)

      scouting = Warlord.siderian_scouting(state, 8, 40)
      assert scouting.siderians[8].stage == :scouting
      assert scouting.siderians[8].since == 500.0

      evading = state |> Warlord.advance(20.0) |> Warlord.siderian_evading(8, 41, 40)
      assert evading.siderians[8].stage == :evading
      assert evading.siderians[8].since == 520.0
    end
  end

  describe "research clocks" do
    test "a fresh Warlord is unseeded and nothing is due until the clocks run" do
      state = warlord()

      assert Warlord.research_enabled?(state)
      refute Warlord.research_seeded?(state)
      refute Warlord.research_due?(state)
      refute Warlord.survey_due?(state)
      assert Warlord.research_turn(state) == :patent
      assert Warlord.lex_slot_cap(state) == 1
    end

    test "a purchase comes due every 60 ut and the two kinds take turns" do
      state = Warlord.advance(warlord(), 60.0)
      assert Warlord.research_due?(state)
      refute Warlord.survey_due?(state)

      state = Warlord.research_bought(state, :patent)
      refute Warlord.research_due?(state)
      assert Warlord.research_turn(state) == :lex

      state = state |> Warlord.advance(60.0) |> Warlord.research_bought(:lex)
      assert Warlord.research_turn(state) == :patent
    end

    test "an empty turn restarts the clock without changing whose turn it is" do
      state = warlord() |> Warlord.advance(75.0) |> Warlord.restart_research()

      refute Warlord.research_due?(state)
      assert Warlord.research_turn(state) == :patent
    end

    test "the clock buys a building patent once a day; the patents' other turns pass" do
      state = Warlord.advance(warlord(), 60.0)
      assert Warlord.patent_interval(state) == 480.0
      # none bought yet: the first is due at once
      assert Warlord.patent_due?(state)

      state = Warlord.research_bought(state, :patent)
      refute Warlord.patent_due?(state)

      # A patent turn that finds none due is passed: the clock restarts and
      # the lexes are next, so they keep their own pace.
      state = state |> Warlord.advance(120.0) |> Warlord.research_passed(:patent)
      refute Warlord.research_due?(state)
      assert Warlord.research_turn(state) == :lex
      refute Warlord.patent_due?(state)

      # a lex purchase does not move the patent clock
      state = state |> Warlord.advance(60.0) |> Warlord.research_bought(:lex)
      refute Warlord.patent_due?(state)

      assert state |> Warlord.advance(300.0) |> Warlord.patent_due?()
    end

    test "stages are counted in days elapsed, from zero" do
      assert Warlord.elapsed_days(warlord()) == 0.0
      assert Warlord.elapsed_days(Warlord.advance(warlord(), 2400.0)) == 5.0
      assert Warlord.match_day(Warlord.advance(warlord(), 2400.0)) == 6
    end

    test "a snapshot from before the patent clock restores with a patent due" do
      old = warlord() |> Warlord.research_bought(:lex) |> Map.update!(:research, &Map.delete(&1, :patent_at))

      assert Warlord.patent_due?(old)
      assert Warlord.summary(old).research.patent_due
    end

    test "the survey comes due every 120 ut, keeps the humans' slot count and asks for an enactment" do
      state = Warlord.advance(warlord(), 120.0)
      assert Warlord.survey_due?(state)
      refute Warlord.enact_pending?(state)

      state = Warlord.mark_surveyed(state, 8)
      refute Warlord.survey_due?(state)
      assert Warlord.lex_slot_cap(state) == 8
      assert Warlord.enact_pending?(state)
      refute state |> Warlord.set_enact_pending(false) |> Warlord.enact_pending?()
    end

    test "seeding is remembered and the readout encodes" do
      state = warlord() |> Warlord.mark_research_seeded() |> Warlord.advance(10.0)

      assert Warlord.research_seeded?(state)
      summary = Warlord.summary(state)
      assert summary.research.seeded
      assert summary.research.next_kind == :patent
      assert summary.research.next_purchase_in_ut == 50.0
      assert summary.research.next_survey_in_ut == 110.0
      assert is_binary(Jason.encode!(summary))
    end

    test "a snapshot taken before research existed restores unseeded, with both clocks at zero" do
      old = Map.drop(warlord(), [:research_accum, :survey_accum, :research])
      refute Map.has_key?(old, :research)

      restored = Warlord.advance(old, 5.0)

      assert restored.research_accum == 5.0
      assert restored.survey_accum == 5.0
      refute Warlord.research_seeded?(restored)
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

  describe "Erased roster" do
    test "the first Erased is hired at once, the next after a full interval" do
      state = warlord()
      assert Warlord.erased_hire_due?(state)

      state = Warlord.track_erased(state, 7, %{theatre: :home, duty: :training, train_target: 4})
      refute Warlord.erased_hire_due?(state)

      assert state |> Warlord.advance(120.0) |> Warlord.erased_hire_due?()
    end

    test "an empty market defers the next look instead of retrying every pass" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})
        |> Warlord.advance(120.0)
        |> Warlord.defer_erased_hire()

      refute Warlord.erased_hire_due?(state)
      assert state |> Warlord.advance(10.0) |> Warlord.erased_hire_due?()
    end

    test "a posting is tracked, re-posted on graduation, and dropped when the agent goes" do
      state = Warlord.track_erased(warlord(), 7, %{theatre: :home, duty: :training, train_target: 5})
      assert %{theatre: :home, duty: :training, train_target: 5, stage: :idle} = state.erased[7]

      state = Warlord.repost_erased(state, 7, :field, :sabotage)
      assert %{theatre: :field, duty: :sabotage, train_target: nil} = state.erased[7]

      assert Warlord.forget_erased(state, 7).erased == %{}
    end

    test "a field informer sent forward holds a forward posting from then on" do
      state =
        warlord()
        |> Warlord.track_erased(1, %{theatre: :field, duty: :infiltration})
        |> Warlord.track_erased(2, %{theatre: :field, duty: :removal})
        |> Warlord.repost_erased(1, :forward, :scout)
        |> Warlord.repost_erased(2, :forward, :deep)

      assert Wave.Erased.forward_held(state.erased) == %{scout: 1, deep: 1}
      assert Warlord.erased_postings(state) == %{"forward/scout" => 1, "forward/deep" => 1}

      # Lost with its agent, the posting is open again.
      state = Warlord.forget_erased(state, 1)
      assert Wave.Erased.forward_vacancies(%{scout: 1, deep: 1}, Wave.Erased.forward_held(state.erased)) == [:scout]
    end

    test "postings roll up into a readable shape of the force" do
      state =
        warlord()
        |> Warlord.track_erased(1, %{theatre: :home, duty: :removal})
        |> Warlord.track_erased(2, %{theatre: :field, duty: :sabotage})
        |> Warlord.track_erased(3, %{theatre: :field, duty: :sabotage})

      assert Warlord.erased_postings(state) == %{"home/removal" => 1, "field/sabotage" => 2}
    end

    test "commitments free up the moment an Erased leaves the roster" do
      state =
        warlord()
        |> Warlord.track_erased(1, %{theatre: :field, duty: :removal})
        |> Warlord.track_erased(2, %{theatre: :field, duty: :removal})
        |> Warlord.erased_dispatched(1, 40, %{target_key: {:character, 99}, target_character: 99})
        |> Warlord.erased_dispatched(2, 40, %{target_key: {:character, 99}, target_character: 99})

      assert Warlord.erased_commitments(state) == %{{:character, 99} => 2}
      assert Warlord.erased_commitments(state, 1) == %{{:character, 99} => 1}
      assert Warlord.erased_commitments(Warlord.forget_erased(state, 1)) == %{{:character, 99} => 1}
    end
  end

  describe "market rank mix" do
    test "each kind of hire has its own steps, by days elapsed" do
      state = warlord()

      assert Warlord.rank_mix(state, :navarch) == {0, %{common: 95, remarkable: 5}}
      assert Warlord.rank_mix(state, :siderian) == {0, %{common: 100}}
      assert Warlord.rank_mix(state, :erased) == {0, %{common: 80, remarkable: 20}}

      day = fn days -> Warlord.advance(state, 480.0 * days) end

      assert Warlord.rank_mix(day.(4.9), :siderian) == {0, %{common: 100}}
      assert Warlord.rank_mix(day.(5), :siderian) == {5, %{common: 40, remarkable: 60}}
      assert Warlord.rank_mix(day.(10.9), :erased) == {8, %{common: 40, remarkable: 60}}
      assert {11, %{exceptional: 15}} = Warlord.rank_mix(day.(11), :erased)
      assert {14, %{exceptional: 25}} = Warlord.rank_mix(day.(14), :siderian)
      assert {8, mix} = Warlord.rank_mix(day.(16.9), :navarch)
      refute Map.has_key?(mix, :exceptional)
      assert {17, %{exceptional: 7}} = Warlord.rank_mix(day.(17), :navarch)
    end

    test "only the ranks with a weight can be bought; colonisers take the cheapest of them" do
      state = warlord()

      assert Warlord.open_ranks(state, :siderian) == [:common]
      assert Warlord.open_ranks(state, :navarch) == [:common, :remarkable]
      assert Warlord.open_ranks(Warlord.advance(state, 480.0 * 20), :erased) == [:common, :remarkable, :exceptional]
      assert Warlord.rank_order(state, :siderian) == [:common]
    end

    test "the rank owed the most comes first, then the nearest others, cheaper first" do
      two = %{common: 40, remarkable: 60}
      assert Warlord.order_ranks(two, %{}) == [:remarkable, :common]
      assert Warlord.order_ranks(two, %{remarkable: 1}) == [:common, :remarkable]
      assert Warlord.order_ranks(two, %{common: 1, remarkable: 1}) == [:remarkable, :common]

      # equal shares: the cheaper rank first
      assert Warlord.order_ranks(%{common: 50, remarkable: 50}, %{}) == [:common, :remarkable]

      three = %{common: 40, remarkable: 35, exceptional: 25}
      assert Warlord.order_ranks(three, %{}) == [:common, :remarkable, :exceptional]
      # common and exceptional are both one away from remarkable: common first
      assert Warlord.order_ranks(three, %{common: 1}) == [:remarkable, :common, :exceptional]
      assert Warlord.order_ranks(three, %{common: 1, remarkable: 1}) == [:exceptional, :remarkable, :common]

      # a rank without weight is never offered, whatever was bought before
      assert Warlord.order_ranks(%{common: 100}, %{remarkable: 3}) == [:common]
      assert Warlord.order_ranks(%{}, %{}) == []
    end

    test "hires come out at the mix even when the cheap rank often has nobody able" do
      # Siderians from day 5: 40% common. The common rank has someone with the
      # trade on only every other look, so a hire that drew its rank would
      # come out 20% common; the ones that fall through to remarkable count
      # for it, and common comes first until it has caught up.
      state = Warlord.advance(warlord(), 480.0 * 6)

      {state, _} =
        Enum.reduce(1..150, {state, 0}, fn _, {acc, look} ->
          ranks = Warlord.rank_order(acc, :siderian)
          available = if rem(look, 2) == 0, do: ranks, else: List.delete(ranks, :common)
          {Warlord.record_hire_rank(acc, :siderian, hd(available)), look + 1}
        end)

      %{siderian: %{hired: hired}} = Warlord.summary(state).hire_ranks
      assert hired.common + hired.remarkable == 150
      assert hired.common in 59..61
    end

    test "a new step of the mix starts its count again" do
      state =
        warlord()
        |> Warlord.advance(480.0 * 6)
        |> Warlord.record_hire_rank(:siderian, :remarkable)
        |> Warlord.record_hire_rank(:siderian, :remarkable)

      assert Warlord.rank_order(state, :siderian) == [:common, :remarkable]

      later = Warlord.advance(state, 480.0 * 8)
      assert Warlord.rank_order(later, :siderian) == [:common, :remarkable, :exceptional]
      assert %{siderian: %{from_day: 14, hired: %{}}} = Warlord.summary(later).hire_ranks
    end

    test "an instance's own mix replaces the default, and a broken one falls back to hire_rank" do
      iid = System.unique_integer([:positive])

      Test.FleetScenario.load_game_data(iid,
        speed: :slow,
        mode: :prod,
        wave: true,
        wave_config: %{
          "bot_faction" => "rebellion",
          "hire_rank" => "remarkable",
          "hire_rank_mix" => %{
            "erased" => [[0, %{"exceptional" => 1, "common" => 0, "legendary" => 5}]],
            "siderian" => [[0, %{"common" => 0}], "nonsense"]
          }
        }
      )

      state = Warlord.new(iid, :rebellion)

      assert Warlord.rank_mix(state, :erased) == {0, %{exceptional: 1}}
      assert Warlord.rank_mix(state, :siderian) == {0, %{remarkable: 1}}
      # a kind the instance's mix leaves out has no steps either
      assert Warlord.rank_mix(state, :navarch) == {0, %{remarkable: 1}}
    end
  end

  describe "Erased practice" do
    test "a system's Intelligence is known only once a result has reported it, and the latest report wins" do
      state = warlord()
      assert Warlord.known_ci(state, 40) == nil

      state = state |> Warlord.learn_intel(40, 3) |> Warlord.advance(10.0) |> Warlord.learn_intel(40, 0)

      assert Warlord.known_ci(state, 40) == 0.0
      assert state.erased_intel[40].at == 10.0
      assert Warlord.summary(state).intel_known == 1
    end

    test "a failed infiltration is timed from when it happened and outlives later reports" do
      state = warlord() |> Warlord.learn_intel(40, 48.5)
      assert Warlord.failed_ago(state, 40) == nil

      state = state |> Warlord.advance(10.0) |> Warlord.infiltration_failed(40) |> Warlord.advance(30.0)
      assert Warlord.failed_ago(state, 40) == 30.0
      assert Warlord.known_ci(state, 40) == 48.5

      state = Warlord.learn_intel(state, 40, 60)
      assert Warlord.known_ci(state, 40) == 60.0
      assert Warlord.failed_ago(state, 40) == 30.0
    end

    test "practice is scored apart from the strikes" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})
        |> Warlord.erased_dispatched(7, 40, %{action: "infiltrate", training: true, cover: 90.0})
        |> Warlord.advance(50.0)

      {state, payload} = Warlord.resolve_erased(state, 7, %{cover_after: 65.0})

      assert payload.training == true
      assert state.stats.practice_resolved == 1
      assert state.stats.erased_resolved == 0
      # The next order starts clean.
      assert state.erased[7].training == nil
    end

    test "the training Navarch is remembered and forgotten" do
      state = Warlord.set_training_dummy(warlord(), 31)
      assert Warlord.training_dummy(state) == 31
      assert Warlord.summary(state).training_dummy == 31
      assert state |> Warlord.set_training_dummy(nil) |> Warlord.training_dummy() == nil
    end

    test "a snapshot from before practice restores with nothing learned and no training Navarch" do
      restored = warlord() |> Map.drop([:erased_intel, :training_dummy]) |> Warlord.upgrade()

      assert restored.erased_intel == %{}
      assert Warlord.training_dummy(restored) == nil
      assert Warlord.known_ci(restored, 40) == nil
    end
  end

  describe "Siderian trades" do
    test "a hire keeps the role it was bought for; entries from before roles were capturers" do
      state = warlord() |> Warlord.track_siderian(1, :destab) |> Warlord.track_siderian(2)
      assert Warlord.siderian_role(state.siderians[1]) == :destab
      assert Warlord.siderian_role(state.siderians[2]) == :capture
      assert Warlord.siderian_role(%{stage: :idle, target: nil}) == :capture
    end

    test "converts count toward nothing: not the ceiling, not the hire clock" do
      state =
        warlord()
        |> Warlord.track_siderian(1, :destab)
        |> Warlord.advance(50.0)
        |> Warlord.adopt_siderian(2, :seduce)
        |> Warlord.adopt_erased(3, %{theatre: :field, duty: :removal})

      assert Warlord.siderian_counts(state) == %{destab: 1}
      assert Warlord.hired_siderian_count(state) == 1
      assert Warlord.hired_erased_count(state) == 0
      assert state.siderian_accum == 50.0
      assert state.erased_accum == 50.0
      assert state.erased[3].converted
      # With only a convert on the Erased roster, the first real hire is still immediate.
      assert Warlord.erased_hire_due?(%{state | erased_accum: 0.0})
    end

    test "capture slots and sector work only count capturers" do
      state =
        warlord()
        |> Warlord.track_siderian(1, :capture)
        |> Warlord.track_siderian(2, :destab)
        |> Warlord.siderian_dispatched(1, 40, %{})
        |> Warlord.siderian_dispatched(2, 41, %{action: "encourage_hate", target_key: {:system, 41}})

      assert Warlord.commitments(state) == %{40 => 1}
      assert Warlord.pending_by_sector(state, %{40 => 7, 41 => 8}) == %{7 => 1}
      assert Warlord.role_commitments(state, :destab) == %{{:system, 41} => 1}
      assert Warlord.role_commitments(state, :destab, 2) == %{}
    end

    test "a destabilization is scored apart from captures, practice apart from strikes" do
      state =
        warlord()
        |> Warlord.track_siderian(1, :destab)
        |> Warlord.track_siderian(2, :destab)
        |> Warlord.siderian_dispatched(1, 40, %{action: "encourage_hate", training: false, target_key: {:system, 40}})
        |> Warlord.siderian_dispatched(2, 41, %{action: "encourage_hate", training: true, target_key: {:system, 41}})
        |> Warlord.advance(60.0)

      {state, payload} = Warlord.resolve_siderian_action(state, 1, %{penalty: 15})
      assert payload.outcome == :performed
      {state, _payload} = Warlord.resolve_siderian_action(state, 2, %{penalty: 20})

      assert state.stats.destab_resolved == 1
      assert state.stats.destab_practice_resolved == 1
      assert state.stats.destab_penalty == 35
      assert Map.get(state.stats, :captured, 0) == 0
      assert state.siderians[1].stage == :idle
      refute Map.has_key?(state.siderians[1], :action)
    end

    test "a seduction worked, missed, or never happened" do
      base =
        warlord()
        |> Warlord.track_siderian(1, :seduce)
        |> Warlord.siderian_dispatched(1, 40, %{action: "conversion", target_character: 9, target_key: {:character, 9}})

      {converted, _} = Warlord.resolve_siderian_action(base, 1, %{converted: true, cooldown_started: true})
      {missed, _} = Warlord.resolve_siderian_action(base, 1, %{converted: false, cooldown_started: true})
      {never, _} = Warlord.resolve_siderian_action(base, 1, %{converted: false, cooldown_started: false})

      assert converted.stats.seductions_succeeded == 1
      assert missed.stats.seductions_failed == 1
      assert never.stats.seductions_aborted == 1
    end

    test "an evading Siderian holds no slot and remembers where it came from" do
      state =
        warlord()
        |> Warlord.track_siderian(1, :destab)
        |> Warlord.siderian_evading(1, 12, 11)

      assert state.siderians[1].stage == :evading
      assert Warlord.role_commitments(state, :destab) == %{}
      assert state.stats.evasions == 1

      state = Warlord.siderian_released(state, 1)
      assert state.siderians[1].stage == :idle
      assert state.siderians[1].came_from == 11
    end

    test "stability readings fold in reports and read back an estimate" do
      state = warlord() |> Warlord.record_destab(40, 6.0, 15, 0.01, -30)
      assert Wave.Siderian.estimate(Warlord.siderian_reading(state, 40), state.elapsed, 0.01) == -9.0
      assert Warlord.siderian_reading(state, 41) == nil
    end

    test "seduced Navarchs wait in reserve until colonisation wants one" do
      state = warlord() |> Warlord.hold_convert_navarch(5)
      assert Map.keys(Warlord.convert_navarchs(state)) == [5]
      assert state |> Warlord.release_convert_navarch(5) |> Warlord.convert_navarchs() == %{}
    end

    test "a snapshot from before the trades restores with empty readings, ground and reserve" do
      restored = warlord() |> Map.drop([:siderian_intel, :destab_ground, :convert_navarchs]) |> Warlord.upgrade()

      assert restored.siderian_intel == %{}
      assert Warlord.destab_ground(restored) == nil
      assert Warlord.convert_navarchs(restored) == %{}
    end

    test "only a capturer's first action counts as a capture started" do
      state =
        warlord()
        |> Warlord.track_siderian(1, :destab)
        |> Warlord.siderian_dispatched(1, 40, %{action: "encourage_hate"})

      {state, [_event]} = Warlord.observe_siderian(state, 1, :acting, :encourage_hate)
      assert Map.get(state.stats, :capture_started, 0) == 0
      assert state.stats.siderian_action_started == 1
    end
  end

  describe "Erased roaming" do
    test "a roamer holds a slot but scores nothing when it arrives" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})
        |> Warlord.erased_roaming(7, 40, %{action: "roam", target_key: {:system, 40}, move_only: true})

      assert state.erased[7].stage == :roaming
      assert Warlord.erased_commitments(state) == %{{:system, 40} => 1}

      # Arrival frees the slot without an attempt being recorded.
      state = Warlord.erased_released(state, 7)
      assert Warlord.erased_commitments(state) == %{}
      assert state.stats.erased_resolved == 0
      assert state.stats.erased_aborted == 0
    end
  end

  describe "Erased telemetry" do
    test "time is charged to the state the agent was in when it was last seen" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})

      {state, []} = Warlord.observe_erased(state, 7, :moving, :moving)
      state = Warlord.advance(state, 6.0)
      {state, []} = Warlord.observe_erased(state, 7, :resting, :idle)
      state = Warlord.advance(state, 4.0)
      {state, []} = Warlord.observe_erased(state, 7, :idle, :idle)

      assert state.erased[7].time == %{moving: 6.0, resting: 4.0}
      assert state.telemetry.erased_ut == %{moving: 6.0, resting: 4.0}
    end

    test "a dispatched Erased seen acting marks its attempt started, once" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})
        |> Warlord.erased_dispatched(7, 40, %{action: "assassination", target_character: 99})
        |> Warlord.advance(5.0)

      {state, events} = Warlord.observe_erased(state, 7, :acting, :assassination)
      assert [{:started, 7, %{travel_ut: 5.0, target: 40}}] = events
      assert state.stats.erased_started == 1

      {_state, events} = Warlord.observe_erased(state, 7, :acting, :assassination)
      assert events == []
    end

    test "a strike that ran is scored with what it achieved, and frees the slot" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :field, duty: :removal})
        |> Warlord.erased_dispatched(7, 40, %{
          action: "assassination",
          target_character: 99,
          target_key: {:character, 99}
        })
        |> Warlord.advance(5.0)

      {state, _} = Warlord.observe_erased(state, 7, :acting, :assassination)
      state = Warlord.advance(state, 2.0)
      {state, payload} = Warlord.resolve_erased(state, 7, %{removed: true})

      assert payload.outcome == :performed
      assert payload.travel_ut == 5.0
      assert payload.action_ut == 2.0
      assert payload.removed == true
      assert state.stats.removals_succeeded == 1
      assert state.erased[7].target_key == nil
      assert Warlord.erased_commitments(state) == %{}
    end

    test "a strike that never started is aborted, not failed" do
      state =
        warlord()
        |> Warlord.track_erased(7, %{theatre: :home, duty: :sabotage})
        |> Warlord.erased_dispatched(7, 40, %{action: "sabotage", target_character: 99})
        |> Warlord.advance(3.0)

      {state, payload} = Warlord.resolve_erased(state, 7, %{tiles_before: 8, tiles_after: 8})

      assert payload.outcome == :aborted
      assert payload.action_ut == nil
      assert state.stats.erased_aborted == 1
    end

    test "resolving an Erased we never tracked is a no-op" do
      assert {_state, nil} = Warlord.resolve_erased(warlord(), 404)
    end
  end

  describe "recon freshness" do
    test "the first pass always reads, then holds the reading for the interval" do
      state = warlord()
      assert Warlord.recon_due?(state, 3.0)

      state = state |> Warlord.advance(1.0) |> Warlord.mark_recon()
      refute Warlord.recon_due?(state, 3.0)

      assert state |> Warlord.advance(3.0) |> Warlord.recon_due?(3.0)
    end
  end

  describe "itinerary with action data" do
    test "an Erased attack names its victim alongside the system" do
      assert Warlord.itinerary([{10, 20}], "assassination", 20, %{"target_character" => 99}) == [
               %{"type" => "jump", "data" => %{"source" => 10, "target" => 20}},
               %{"type" => "assassination", "data" => %{"target" => 20, "target_character" => 99}}
             ]
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
