defmodule Instance.ResourceMarket.ResourceMarketTest do
  @moduledoc """
  The galactic tech/ideology value index: pooled-income target, capped
  squared-gap drift, daily market events (scaled by faction count) and short
  shocks, report staleness, and the public view never exposing the target.

  A constant `rand` of 0.5 makes every uniform draw its midpoint: rolls equal
  the shift, events have size 0, and every day's shocks land on step 12.
  """
  use ExUnit.Case, async: true

  alias Instance.ResourceMarket.Agent
  alias Instance.ResourceMarket.ResourceMarket

  defp mid, do: 0.5

  defp market(faction_count \\ 2), do: ResourceMarket.new(1, faction_count)

  defp with_reports(state, reports) do
    Enum.reduce(reports, state, fn {pid, fid, c, t, i}, acc ->
      ResourceMarket.report_income(acc, pid, fid, %{credit: c, technology: t, ideology: i})
    end)
  end

  defp price(state, resource), do: state.prices[resource]

  test "prices start at the 10:1 baseline" do
    assert %{technology: 10.0, ideology: 10.0} = market().prices
  end

  test "the target pools every player's income (not an average of faction ratios)" do
    state =
      market()
      |> with_reports([{1, 1, 4_000, 350, 500}, {2, 1, 0, 0, 0}, {3, 2, 3_500, 300, 415}])

    assert_in_delta ResourceMarket.target(state, :technology), 7_500 / 650, 1.0e-9
    assert_in_delta ResourceMarket.target(state, :ideology), 7_500 / 915, 1.0e-9
  end

  test "reports older than a game day stop counting" do
    state = market() |> with_reports([{1, 1, 1_000, 100, 100}])
    assert ResourceMarket.target(state, :technology) == 10.0

    state = ResourceMarket.next_tick(state, 500, &mid/0)
    assert ResourceMarket.target(state, :technology) == nil
  end

  test "gross income sums the positive parts of a resource value" do
    dv = %Core.DynamicValue{
      value: 0,
      change: 50,
      details: %{
        system: [%Core.ValuePart{value: 120, reason: :a}, %Core.ValuePart{value: 30, reason: :b}],
        misc: [%Core.ValuePart{value: -100, reason: :upkeep}]
      }
    }

    assert ResourceMarket.gross_income(dv) == 150.0
  end

  test "one step per 20 UT, each recorded in the history" do
    state = market() |> with_reports([{1, 1, 2_000, 100, 100}]) |> ResourceMarket.next_tick(60, &mid/0)

    assert state.step_count == 3
    assert length(state.history) == 3
    assert ResourceMarket.compute_next_tick_interval(state) == 20
  end

  test "far below the target, the price climbs at the capped rate (+0.4% an hour at the midpoint)" do
    # target 20, price 10: gap² = 100, capped at 4 points, ÷10 → +0.4%
    state = market() |> with_reports([{1, 1, 2_000, 100, 100}]) |> ResourceMarket.next_tick(11 * 20, &mid/0)
    assert_in_delta price(state, :technology), 10 * :math.pow(1.004, 11), 1.0e-9
  end

  test "above the target, the price falls" do
    state = market() |> with_reports([{1, 1, 800, 100, 100}]) |> ResourceMarket.next_tick(20, &mid/0)
    assert_in_delta price(state, :technology), 10 * 0.996, 1.0e-9
  end

  test "a small gap barely moves the price (the shift is squared)" do
    # target 10.5: gap 0.5 → shift 0.25 points → +0.025%
    state = market() |> with_reports([{1, 1, 1_050, 100, 100}]) |> ResourceMarket.next_tick(20, &mid/0)
    assert_in_delta price(state, :technology), 10 * 1.00025, 1.0e-9
  end

  test "without income reports the price holds (apart from shocks)" do
    state = ResourceMarket.next_tick(market(), 11 * 20, &mid/0)
    assert price(state, :technology) == 10.0
  end

  test "each game day schedules one event and two shocks per resource" do
    state = market() |> with_reports([{1, 1, 2_000, 100, 100}]) |> ResourceMarket.next_tick(20, &mid/0)

    for resource <- ResourceMarket.resources() do
      assert [%{step: 12}] = state.events[resource]
      assert [12, 12] = state.shocks[resource]
    end

    state = ResourceMarket.next_tick(state, 24 * 20, &mid/0)
    assert state.scheduled_day == 1
    assert Enum.all?(state.shocks.technology, &(&1 in 24..47))
  end

  test "a shock step jumps within ±2% whatever the economy" do
    # rand sequence: day scheduling draws first, then the step's move
    draws = :ets.new(:draws, [:public])
    :ets.insert(draws, {:n, 0})

    # step 0: every scheduling draw 0.0 → events at step 0 (size −15%) and
    # shocks at step 0; the shock move itself draws 1.0 → +2%
    rand = fn ->
      n = :ets.update_counter(draws, :n, 1)
      if n <= 2 * (2 + 2), do: 0.0, else: 0.999999
    end

    state = market() |> with_reports([{1, 1, 5_000, 100, 100}]) |> ResourceMarket.next_tick(20, rand)
    assert_in_delta price(state, :technology), 10 * 1.02, 1.0e-3
  end

  test "event size shrinks with more factions" do
    assert_in_delta ResourceMarket.event_size(market(1)), 0.15, 1.0e-9
    assert_in_delta ResourceMarket.event_size(market(2)), 0.15, 1.0e-9
    assert_in_delta ResourceMarket.event_size(market(3)), 0.10, 1.0e-9
    assert_in_delta ResourceMarket.event_size(market(5)), 0.06, 1.0e-9
  end

  test "an event scales the target and fades with a 240 UT half-life" do
    base = market() |> with_reports([{1, 1, 1_000, 100, 100}])
    # hand-placed +100% event at step 0; price already at the base target
    state = %{
      base
      | prices: %{technology: 10.0, ideology: 10.0},
        scheduled_day: 0,
        events: %{technology: [%{step: 0, size: 1.0}], ideology: []},
        shocks: %{technology: [], ideology: []}
    }

    # step 0: target 20 → capped +0.4%
    stepped = ResourceMarket.next_tick(state, 20, &mid/0)
    assert_in_delta price(stepped, :technology), 10.04, 1.0e-9
    assert price(stepped, :ideology) == 10.0

    # 12 steps (240 UT) later the event is at half strength: target 15.
    # From 14 the gap is 1 → shift 1 point → +0.1% (a full-strength target
    # of 20 would give the capped +0.4%).
    later = %{
      state
      | step_count: 12,
        next_step: 13 * 20.0,
        clock: 12 * 20.0,
        prices: %{technology: 14.0, ideology: 10.0}
    }

    later = ResourceMarket.next_tick(later, 20, &mid/0)
    assert_in_delta price(later, :technology), 14 * 1.001, 1.0e-9
  end

  test "hourly moves stay within ±2% with real randomness" do
    state = market(2) |> with_reports([{1, 1, 3_000, 100, 200}, {2, 2, 1_000, 90, 50}])

    final =
      Enum.reduce(1..(24 * 20), state, fn _, acc ->
        before = acc.prices
        acc = ResourceMarket.next_tick(acc, 20)

        for r <- ResourceMarket.resources() do
          assert abs(acc.prices[r] / before[r] - 1) <= 0.020_001
        end

        # keep reports fresh
        with_reports(acc, [{1, 1, 3_000, 100, 200}, {2, 2, 1_000, 90, 50}])
      end)

    # 20 days of drift toward target 40/1.9 ≈ 21 (tech) from 10
    assert final.prices.technology > 15
  end

  test "crypto_uniform is in [0, 1)" do
    for _ <- 1..1_000, do: assert(ResourceMarket.crypto_uniform() >= 0 and ResourceMarket.crypto_uniform() < 1)
  end

  test "the public view has prices and history, never the target or reports" do
    state = market() |> with_reports([{1, 1, 2_000, 100, 100}]) |> ResourceMarket.next_tick(40, &mid/0)
    view = ResourceMarket.public(state)

    assert Map.keys(view) |> Enum.sort() == [:base_price, :history, :prices, :step_ut]
    assert [%{step: 0}, %{step: 1}] = Enum.map(view.history, &Map.take(&1, [:step]))
    refute inspect(view) =~ "faction_id"
  end

  describe "agent" do
    test "income reports are cast in; ticks advance the market; the public view is served" do
      iid = System.unique_integer([:positive])

      state = %Core.GenState{
        type: :resource_market,
        instance_id: iid,
        speed: :slow,
        agent_id: :master,
        data: ResourceMarket.new(iid, 2),
        channel: nil,
        # 1 UT = 10 ms of wall time; clock shifted 40 UT into the past
        tick: %Core.Tick{time: Instance.Time.Time.now(0) - 400, factor: 18_000, cumulated_pauses: 0, running?: true},
        kill: false
      }

      {:noreply, state} =
        Agent.on_cast({:report_income, 7, 1, %{credit: 2_000.0, technology: 100.0, ideology: 100.0}}, state)

      assert map_size(state.data.reports) == 1

      {:reply, {:ok, view}, _state} = Agent.on_call(:get_public, self(), state)
      assert length(view.history) >= 2
      assert Map.has_key?(view.prices, :technology)
    end
  end
end
