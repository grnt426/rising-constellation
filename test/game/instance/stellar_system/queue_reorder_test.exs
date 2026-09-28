defmodule Instance.StellarSystem.QueueReorderTest do
  @moduledoc """
  Players can drag their construction queue into a new order. Only the head
  of the queue accumulates production, and progress is deliberately NOT
  carried across a reorder: a displaced head is reset to its full cost.

  The rule these tests pin down is that reordering can never make anything
  finish earlier than it would have had it been queued in that order from
  the start — in particular, dragging an expensive item ahead of a cheap one
  that is about to complete must neither complete the cheap one nor hand
  its progress to the expensive one.

  The agent-level scenarios drive the real `Instance.StellarSystem.Agent`
  handler (tick_rearm: settle elapsed production into the OLD head, run the
  reorder, re-arm the timer for the NEW head) with a `Core.Tick` shifted
  into the past, as in `QueueEtaSyncTest`. Factor 18 makes 1 UT = 10 s.
  """
  use ExUnit.Case, async: false

  alias Instance.StellarSystem.Agent, as: SystemAgent
  alias Instance.StellarSystem.{ProductionItem, ProductionQueue, StellarSystem}
  alias Test.FleetScenario

  @factor 18
  @ms_per_ut 10_000
  @owner_id 7
  # production per UT of the test capital; a level-1 hab_open costs 30
  # production on :slow, so it completes in exactly 1 UT
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

  # ---------------------------------------------------------------------------
  # pure queue rules
  # ---------------------------------------------------------------------------

  describe "ProductionQueue.reorder/2" do
    test "reordering behind an unchanged head keeps the head's progress" do
      queue = queue_of([{1, 100, 40}, {2, 50, 50}, {3, 80, 80}])

      assert {:ok, reordered} = ProductionQueue.reorder(queue, [1, 3, 2])
      assert progress(reordered) == [{1, 40}, {3, 80}, {2, 50}]
    end

    test "displacing the head resets its progress; the new head starts from scratch" do
      # item 1 (cheap) is 90% done; item 2 (expensive) is dragged ahead
      queue = queue_of([{1, 30, 3}, {2, 300, 300}])

      assert {:ok, reordered} = ProductionQueue.reorder(queue, [2, 1])
      assert progress(reordered) == [{2, 300}, {1, 30}]
    end

    test "moving the head back and forth never recovers lost progress" do
      queue = queue_of([{1, 30, 3}, {2, 300, 300}])

      {:ok, swapped} = ProductionQueue.reorder(queue, [2, 1])
      {:ok, restored} = ProductionQueue.reorder(swapped, [1, 2])
      assert progress(restored) == [{1, 30}, {2, 300}]
    end

    test "an identity reorder is a no-op" do
      queue = queue_of([{1, 100, 40}, {2, 50, 50}])
      assert {:ok, same} = ProductionQueue.reorder(queue, [1, 2])
      assert Queue.to_list(same.queue) == Queue.to_list(queue.queue)
    end

    test "anything but an exact permutation of the queued ids is refused" do
      queue = queue_of([{1, 100, 40}, {2, 50, 50}, {3, 80, 80}])

      for ids <- [[1, 2], [1, 2, 3, 4], [1, 1, 2], [1, 2, 2, 3], [4, 2, 1], [], nil, "1,2,3"] do
        assert {:error, :queue_changed} = ProductionQueue.reorder(queue, ids), "accepted #{inspect(ids)}"
      end
    end

    test "an empty queue only accepts the empty order" do
      assert {:ok, _} = ProductionQueue.reorder(ProductionQueue.new(), [])
      assert {:error, :queue_changed} = ProductionQueue.reorder(ProductionQueue.new(), [1])
    end
  end

  describe "ids stay unique once the queue can be reordered" do
    test "a new item after a reorder gets a fresh id" do
      queue = queue_of([{1, 10, 10}, {2, 10, 10}, {3, 10, 10}])
      {:ok, queue} = ProductionQueue.reorder(queue, [3, 1, 2])

      queue = ProductionQueue.queue_item(queue, :building, {"b", 5, :hab_open, 1, 10})
      ids = Enum.map(Queue.to_list(queue.queue), & &1.id)

      assert ids == [3, 1, 2, 4]
    end

    test "cancelling a reordered item removes exactly that item" do
      queue = queue_of([{1, 10, 10}, {2, 10, 10}, {3, 10, 10}])
      {:ok, queue} = ProductionQueue.reorder(queue, [3, 1, 2])
      queue = ProductionQueue.queue_item(queue, :building, {"b", 5, :hab_open, 1, 10})

      assert {:ok, %{id: 3}, queue} = ProductionQueue.unqueue_item(queue, 3)
      assert Enum.map(Queue.to_list(queue.queue), & &1.id) == [1, 2, 4]
    end
  end

  # ---------------------------------------------------------------------------
  # the real agent handler, with elapsed game time
  # ---------------------------------------------------------------------------

  describe "reordering through the system agent" do
    setup do
      iid = System.unique_integer([:positive])
      Data.Data.insert(iid, speed: :slow, mode: :prod)
      {:ok, rand} = GenServer.start_link(SeededRand, 7, name: Game.via_tuple({iid, :rand, :master}))

      FleetScenario.spawn_fake_player(self(), instance_id: iid, player_id: @owner_id, faction: :myrmezir)

      on_exit(fn ->
        Process.exit(rand, :shutdown)

        try do
          Data.Data.clear(iid)
        rescue
          _ -> :ok
        end
      end)

      system = capital(iid)
      {body_uid, [t1, t2, t3 | _]} = free_tiles(system)

      {:ok, system} = StellarSystem.order_building_production(system, {body_uid, t1, :hab_open, 1})
      {:ok, system} = StellarSystem.order_building_production(system, {body_uid, t2, :hab_open, 1})
      {:ok, system} = StellarSystem.order_building_production(system, {body_uid, t3, :hab_open, 1})

      [a, b, c] = queue(system)
      assert a.total_prod == @rate, "fixture assumes a 1-UT hab_open (got #{a.total_prod})"

      {:ok, iid: iid, system: system, body: body_uid, tiles: [t1, t2, t3], ids: [a.id, b.id, c.id]}
    end

    test "dragging another item ahead of a nearly finished head completes nothing early",
         %{iid: iid, system: system, body: body, tiles: [t1, t2, _], ids: [a, b, c]} do
      # 0.9 UT in, the head is 90% built: 3 production from done
      {:reply, {:ok, reordered}, state} =
        SystemAgent.on_call({:reorder_production, [b, a, c]}, self(), gen_state(iid, system, 0.9))

      [head, second, third] = queue(reordered)
      assert {head.id, second.id, third.id} == {b, a, c}

      # the displaced head lost its 27 production; nothing moved to the new head
      assert_in_delta second.remaining_prod, @rate, 0.01
      assert_in_delta head.remaining_prod, @rate, 0.01
      assert_in_delta third.remaining_prod, @rate, 0.01
      assert tile(reordered, body, t1).construction_status == :new
      assert tile(reordered, body, t1).building_status == :empty

      # the tick timer now targets the NEW head's full cost, not the old
      # head's 0.1 UT
      assert_timer_matches(state, reordered)

      # 0.5 UT later: the old head would have been done 0.4 UT ago in the
      # original order, but nothing has completed
      {:reply, {:ok, later}, _} = SystemAgent.on_call(:get_state, self(), gen_state(iid, reordered, 0.5))

      assert [%{id: ^b} = head, %{id: ^a} = displaced, %{id: ^c}] = queue(later)
      assert_in_delta head.remaining_prod, @rate * 0.5, 0.5
      assert_in_delta displaced.remaining_prod, @rate, 0.01
      assert tile(later, body, t1).building_status == :empty
      assert tile(later, body, t2).building_status == :empty
    end

    test "total completion time for the whole queue never shrinks after a reorder",
         %{iid: iid, system: system, ids: [a, b, c]} do
      before = ProductionQueue.get_total_remaining_time(settled(iid, system, 0.6))

      {:reply, {:ok, reordered}, _} =
        SystemAgent.on_call({:reorder_production, [c, b, a]}, self(), gen_state(iid, system, 0.6))

      assert ProductionQueue.get_total_remaining_time(reordered) >= before
      # exactly the 0.6 UT the displaced head had accumulated is lost
      assert_in_delta ProductionQueue.get_total_remaining_time(reordered) - before, 0.6, 0.02
    end

    test "a head that was due before the reorder arrived completes, and the stale order is refused",
         %{iid: iid, system: system, body: body, tiles: [t1, _, _], ids: [a, b, c]} do
      # 1.2 UT elapsed: the head finished 0.2 UT ago, before this request
      {:reply, {:error, :queue_changed}, state} =
        SystemAgent.on_call({:reorder_production, [b, a, c]}, self(), gen_state(iid, system, 1.2))

      # the legitimate completion stands (it was never undone)...
      assert tile(state.data, body, t1).building_status == :built
      # ...with its overflow already flowing into the next head
      assert [%{id: ^b} = head, %{id: ^c}] = queue(state.data)
      assert_in_delta head.remaining_prod, @rate * 0.8, 0.5
    end

    test "reordering only the tail keeps the head's progress and its schedule",
         %{iid: iid, system: system, ids: [a, b, c]} do
      {:reply, {:ok, reordered}, state} =
        SystemAgent.on_call({:reorder_production, [a, c, b]}, self(), gen_state(iid, system, 0.5))

      assert [%{id: ^a} = head, %{id: ^c}, %{id: ^b}] = queue(reordered)
      assert_in_delta head.remaining_prod, @rate * 0.5, 0.5
      assert_timer_matches(state, reordered)
    end

    test "a refused reorder leaves the queue untouched", %{iid: iid, system: system, ids: [a, b, _c]} do
      {:reply, {:error, :queue_changed}, state} =
        SystemAgent.on_call({:reorder_production, [b, a]}, self(), gen_state(iid, system, 0.3))

      assert Enum.map(queue(state.data), & &1.id) == Enum.map(queue(system), & &1.id)
      assert_in_delta hd(queue(state.data)).remaining_prod, @rate * 0.7, 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp queue_of(specs) do
    items =
      Enum.map(specs, fn {id, total, remaining} ->
        %ProductionItem{
          id: id,
          type: :building,
          target_id: "body",
          tile_id: id + 1,
          prod_key: :hab_open,
          prod_level: 1,
          total_prod: total,
          remaining_prod: remaining
        }
      end)

    %ProductionQueue{queue: Queue.new(items)}
  end

  defp progress(%{queue: q}), do: Enum.map(Queue.to_list(q), &{&1.id, &1.remaining_prod})

  defp queue(system), do: Queue.to_list(system.queue.queue)

  defp settled(iid, system, stale_ut) do
    {:reply, {:ok, data}, _} = SystemAgent.on_call(:get_state, self(), gen_state(iid, system, stale_ut))
    data
  end

  defp tile(system, body_uid, tile_id) do
    body = Enum.find(system.bodies, &(&1.uid == body_uid))
    Enum.find(body.tiles, &(&1.id == tile_id))
  end

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

  # A claimed capital (real starter layout, real Data content) with a stable
  # population, so it only ticks when a queue item is due. Same fixture as
  # QueueEtaSyncTest.
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

  defp free_tiles(system) do
    body =
      Enum.find(system.bodies, fn b ->
        Enum.any?(b.tiles, &(&1.id == 1 and &1.building_status == :built))
      end)

    ids = for t <- body.tiles, t.id > 1, t.building_status == :empty, t.construction_status == :none, do: t.id
    {body.uid, ids}
  end
end
