defmodule Instance.StellarSystem.QueueEtaSyncTest do
  @moduledoc """
  The construction-queue ETA on the system list (hovering the queue pips of a
  `ClosedSystemCard`) comes from `Player.StellarSystem.queue_remaining_time`,
  a snapshot converted from whatever `%StellarSystem{}` the system agent hands
  its owner. The system view computes the same number from a fresh
  `:get_state`. For the two to agree — and for constructions to finish when
  both say they will — every snapshot must come from a system caught up to
  "now", and the agent's next tick must follow production changes.

  Systems with a stable population only tick when their next queue item is
  due, so a production change (a Lex, a governor, a siege) that doesn't
  re-arm the tick timer leaves completion scheduled for the OLD rate: a
  boost finishes late, a slowdown ticks early for nothing.

  Every `on_call`/`on_cast` clause of `Instance.StellarSystem.Agent` is
  wrapped by `@decorate tick_rearm()` (catch up before the body, re-arm the
  timer after it), including clauses without the attribute: the decorator
  library gives undecorated clauses the decorators of the function's first
  decorated clause. The snapshot scenarios below lock that in, since the
  code reads as if `order_building` were undecorated.

  A siege that runs out on its own timer must also lift its production
  penalty — it used to leave a stable-population system at zero production,
  constructions paused indefinitely.

  Each scenario drives the real handlers with a running `Core.Tick` whose
  clock is shifted into the past, so elapsed game time is simulated without
  sleeping. Factor 18 makes 1 UT = 10 s of wall time.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.Agent, as: SystemAgent
  alias Instance.StellarSystem.{ProductionQueue, StellarSystem}
  alias Instance.Player.StellarSystem, as: Snapshot
  alias Test.FleetScenario

  @factor 18
  @ms_per_ut 10_000
  @owner_id 7
  # production per UT of the test capital: the 30-production hab_open then
  # completes in 1 UT, inside the 2 UT population-growth tick cadence
  @rate 30

  defmodule SeededRand do
    use GenServer

    def init(seed) do
      :rand.seed(:exsss, {seed, seed, seed})
      {:ok, nil}
    end

    def handle_call({:uniform}, _from, s), do: {:reply, :rand.uniform(), s}
    def handle_call({:uniform, n}, _from, s), do: {:reply, :rand.uniform(n), s}
    def handle_call({:uniform, min, max}, _from, s), do: {:reply, :rand.uniform() * (max - min) + min, s}
    def handle_call({:random, enum}, _from, s), do: {:reply, Enum.random(enum), s}
    def handle_call({:take_random, list, n}, _from, s), do: {:reply, Enum.take_random(list, n), s}
  end

  setup do
    iid = System.unique_integer([:positive])
    Data.Data.insert(iid, speed: :slow, mode: :prod)
    {:ok, rand} = GenServer.start_link(SeededRand, 7, name: Game.via_tuple({iid, :rand, :master}))

    {_player, owner_pid} =
      FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @owner_id, faction: :myrmezir)

    on_exit(fn ->
      Process.exit(rand, :shutdown)

      try do
        Data.Data.clear(iid)
      rescue
        _ -> :ok
      end
    end)

    {:ok, iid: iid, owner_pid: owner_pid, system: capital(iid)}
  end

  describe "snapshots are taken from a system caught up to now" do
    test "order_building on a system that last ticked 0.5 UT ago", %{iid: iid, system: system} do
      {body_uid, [t1, t2 | _]} = free_tiles(system)
      {:ok, system} = StellarSystem.order_building_production(system, {body_uid, t1, :hab_open, 1})
      cost = building_cost(iid, :hab_open, 1)

      {:reply, {:ok, ordered}, _state} =
        SystemAgent.on_call(
          {:order_building, "build", {body_uid, t2, :hab_open, 1}},
          self(),
          gen_state(iid, system, 0.5)
        )

      assert [first, _second] = queue(ordered)
      assert_in_delta first.remaining_prod, cost - @rate * 0.5, 0.5

      # the owner's snapshot equals what the system view computes
      assert_in_delta Snapshot.convert(ordered).queue_remaining_time, (2 * cost - @rate * 0.5) / @rate, 0.05
    end

    test "an order on an idle system that last ticked 50 UT ago gets no production from before it was queued",
         %{iid: iid, system: system} do
      {body_uid, [t1 | _]} = free_tiles(system)

      {:reply, {:ok, _ordered}, state} =
        SystemAgent.on_call(
          {:order_building, "build", {body_uid, t1, :hab_open, 1}},
          self(),
          gen_state(iid, system, 50)
        )

      # the client refetches right after ordering
      {:reply, {:ok, fetched}, _state} = SystemAgent.on_call(:get_state, self(), state)

      assert [item] = queue(fetched)
      assert_in_delta item.remaining_prod, building_cost(iid, :hab_open, 1), 0.5
    end
  end

  describe "the next tick follows production changes" do
    setup %{iid: iid, system: system} do
      {body_uid, [t1 | _]} = free_tiles(system)
      {:ok, system} = StellarSystem.order_building_production(system, {body_uid, t1, :hab_open, 1})
      # prime a tick so a timer for the current rate is armed
      {:reply, {:ok, _}, state} = SystemAgent.on_call(:get_state, self(), gen_state(iid, system, 0))
      assert_timer_matches(state, state.data)
      {:ok, state: state}
    end

    test "a Lex boosting production pulls completion in", %{state: state} do
      {:reply, boosted, state} = SystemAgent.on_call({:update_bonuses, :player, lex(20)}, self(), state)
      assert boosted.production.value == @rate + 20
      assert_timer_matches(state, boosted)
    end

    test "losing a Lex pushes completion out", %{state: state} do
      {:reply, _, state} = SystemAgent.on_call({:update_bonuses, :player, lex(20)}, self(), state)
      {:reply, slowed, state} = SystemAgent.on_call({:update_bonuses, :player, []}, self(), state)
      assert slowed.production.value == @rate
      assert_timer_matches(state, slowed)
    end

    test "a governor (character bonuses) reschedules", %{state: state} do
      {:reply, governed, state} = SystemAgent.on_call({:update_bonuses, :character, lex(40)}, self(), state)
      assert governed.production.value == @rate + 40
      assert_timer_matches(state, governed)

      {:reply, {:ok, ungoverned}, state} = SystemAgent.on_call({:remove_character, %{id: 1}, :governor}, self(), state)
      assert ungoverned.production.value == @rate
      assert_timer_matches(state, ungoverned)
    end

    test "a siege and its release reschedule, and the owner's snapshot tracks both",
         %{state: state, owner_pid: owner_pid} do
      state = with_besieger(state)
      {:noreply, state} = SystemAgent.on_cast({:besiege, :conquest, 10, 4242}, state)
      assert_timer_matches(state, state.data)

      {:reply, {:ok, released, _logs}, state} =
        SystemAgent.on_call({:release_siege, 0, 0, :normal_success}, self(), state)

      assert released.siege == nil
      assert_timer_matches(state, released)

      updates = FleetScenario.get_system_updates(owner_pid)
      assert [{:update_system, sieged} | _] = updates
      assert sieged.siege != nil
      assert {:update_system, freed} = List.last(updates)
      assert freed.siege == nil

      assert_in_delta Snapshot.convert(freed).queue_remaining_time,
                      ProductionQueue.get_total_remaining_time(released),
                      0.05
    end

    test "a siege expiring on its own timer restores production and tells the owner",
         %{iid: iid, state: state, owner_pid: owner_pid} do
      state = with_besieger(state)
      {:noreply, state} = SystemAgent.on_cast({:besiege, :conquest, 2, 4242}, state)
      assert state.data.production.value < @rate

      # 3 UT later the 2 UT siege has run out
      stale = gen_state(iid, state.data, 3)
      {:reply, {:ok, expired}, state} = SystemAgent.on_call(:get_state, self(), stale)

      assert expired.siege == nil
      assert expired.production.value == @rate
      assert_timer_matches(state, expired)

      assert {:update_system, last} = List.last(FleetScenario.get_system_updates(owner_pid))
      assert last.siege == nil
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp lex(value),
    do: [
      %{reason: {:doctrine, :test}, bonus: %Core.Bonus{from: :direct, to: :sys_production, type: :add, value: value}}
    ]

  # The besieging fleet sits in the system for the whole siege (otherwise the
  # tick's orphan sweep releases it).
  defp with_besieger(state) do
    besieger = struct(Instance.StellarSystem.Character, id: 4242)
    %{state | data: %{state.data | characters: [besieger]}}
  end

  defp queue(system), do: Queue.to_list(system.queue.queue)

  # The armed :tick timer must match the schedule the system's CURRENT state
  # asks for: the queue head completing at the current production rate, or
  # the population cadence if sooner (±250 ms of padding and test time).
  defp assert_timer_matches(state, system) do
    expected_ut = StellarSystem.compute_next_tick_interval(system)
    assert is_number(expected_ut)
    assert is_reference(state.tick.ref), "no tick scheduled"
    scheduled_ms = Process.read_timer(state.tick.ref)
    assert is_integer(scheduled_ms), "tick timer already fired or was cancelled"

    assert_in_delta scheduled_ms,
                    Core.Tick.unit_time_to_millisecond(state.tick, expected_ut),
                    250,
                    "next tick is armed for #{Float.round(scheduled_ms / @ms_per_ut, 2)} UT, " <>
                      "but the current state asks for #{Float.round(expected_ut / 1, 2)} UT"
  end

  defp gen_state(iid, system, stale_ut) do
    now = Instance.Time.Time.now(0)
    tick = %Core.Tick{time: now - trunc(stale_ut * @ms_per_ut), factor: @factor, cumulated_pauses: 0, running?: true}

    %Core.GenState{
      type: :stellar_system,
      instance_id: iid,
      speed: :slow,
      agent_id: system.id,
      data: system,
      channel: "test",
      tick: tick,
      kill: false
    }
  end

  defp building_cost(iid, key, level) do
    building = Data.Querier.one(Data.Game.Building, iid, key)
    Enum.find(building.levels, &(&1.level == level)).production
  end

  # A claimed capital (real starter layout, real Data content) with a stable
  # population, so it only ticks when a queue item is due.
  defp capital(iid) do
    system =
      Enum.find_value(1..100, fn key ->
        s =
          StellarSystem.new(
            %{"key" => key, "type" => "red_dwarf", "position" => %{"x" => 0, "y" => 0}},
            1,
            iid,
            name: "sys-#{key}",
            forced_status: :uninhabited
          )

        if s.status == :uninhabited, do: s
      end)

    owner = %{id: @owner_id, name: "p#{@owner_id}", avatar: "a", faction: :myrmezir, faction_id: 1}
    {_, capital} = StellarSystem.claim(system, owner, true, false)

    # A fresh claim has no workforce (every building would sit behind the
    # workforce penalty): staff it lightly (no uprising) and pin production
    # at @rate under a bonus key of its own, so Lex/governor scenarios stack
    # on top of it.
    capital = %{capital | population: %{Core.DynamicValue.new(12.0) | change: 0}, workforce: 12}
    {_, _, probe} = StellarSystem.update_bonuses(capital, :test_base, [])
    adjust = @rate - probe.production.value

    base = [
      %{reason: {:misc, :test_base}, bonus: %Core.Bonus{from: :direct, to: :sys_production, type: :add, value: adjust}}
    ]

    {_, _, capital} = StellarSystem.update_bonuses(capital, :test_base, base)

    assert capital.production.value == @rate, inspect(capital.production)
    capital
  end

  # Free tiles of the starter planet (the one whose infrastructure, tile 1,
  # is built).
  defp free_tiles(system) do
    body =
      Enum.find(system.bodies, fn b ->
        Enum.any?(b.tiles, &(&1.id == 1 and &1.building_status == :built))
      end)

    ids = for t <- body.tiles, t.id > 1, t.building_status == :empty, t.construction_status == :none, do: t.id
    {body.uid, ids}
  end
end
