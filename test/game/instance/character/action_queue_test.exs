defmodule Instance.Character.ActionQueueTest do
  use ExUnit.Case, async: true

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue

  defp now(cp \\ 0), do: Instance.Time.Time.now(cp)
  defp queue_with(items), do: %ActionQueue{virtual_position: 5, queue: Queue.new(items)}
  defp fresh_lock, do: %{Action.new({:locked, %{lock: true}, 100}) | started_at: now()}
  defp stale_lock, do: %{Action.new({:locked, %{lock: true}, 100}) | started_at: now() - 400_000}
  defp legacy_lock, do: Action.new({:locked, %{lock: true}, 100})

  describe "lock/2" do
    test "stamps the inserted lock with the supplied timestamp" do
      t = now()
      lock = Queue.peek(ActionQueue.lock(ActionQueue.new(), t).queue)
      assert lock.type == :locked
      assert lock.started_at == t
    end
  end

  describe "process_next_action/3 — lock staleness" do
    test "a fresh lock keeps the queue locked (orchestrator round-trip in flight)" do
      assert ActionQueue.process_next_action(queue_with([fresh_lock()]), 1, 0) == :queue_locked
    end

    test "a lock older than the timeout is reported as expired" do
      assert ActionQueue.process_next_action(queue_with([stale_lock()]), 1, 0) == :lock_expired
    end

    test "a legacy lock with no timestamp is treated as expired" do
      assert ActionQueue.process_next_action(queue_with([legacy_lock()]), 1, 0) == :lock_expired
    end

    test "pause time does not age a lock (Time.now is pause-adjusted)" do
      # A lock stamped 'now' under cumulated_pauses cp must read as fresh when
      # evaluated under the same cp, regardless of cp's magnitude.
      cp = 9_000_000
      lock = %{Action.new({:locked, %{lock: true}, 100}) | started_at: now(cp)}
      assert ActionQueue.process_next_action(queue_with([lock]), 1, cp) == :queue_locked
    end
  end

  describe "get_next_action_remaining_time/1" do
    test "a locked head re-ticks on the short poll interval, not its 100-unit total" do
      interval = ActionQueue.get_next_action_remaining_time(queue_with([fresh_lock()]))
      assert is_number(interval)
      assert interval > 0 and interval < 1.0
    end

    test "a normal timed head still reports its own remaining_time" do
      action = Action.new({:infiltrate, %{"target" => 5}, 42.0})
      assert ActionQueue.get_next_action_remaining_time(queue_with([action])) == 42.0
    end
  end
end
