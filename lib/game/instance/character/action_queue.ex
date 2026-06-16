defmodule Instance.Character.ActionQueue do
  use TypedStruct

  alias Instance.Character.Action
  alias Instance.Character.ActionQueue

  require Logger

  # A queue is locked while the action orchestrator runs a start/finish hook
  # out-of-band; it is unlocked when the orchestrator delivers {:done} back to
  # the agent. If that round-trip is lost — the orchestrator crashing and
  # dropping its mailbox during a restore storm, or a {:done} call timing out —
  # the lock would otherwise wedge the character forever ("traveling" /
  # "infiltrating" with no position, un-orderable; Granite & others 2026-06-16).
  # We stamp the lock with a pause-adjusted wall-clock timestamp and treat a
  # lock older than this timeout — or one with no timestamp at all, i.e. a
  # legacy lock from before this mechanism — as stale so the character can
  # self-heal. Generous on purpose: a merely-backlogged orchestrator must never
  # be mistaken for a dead one. A few minutes of wedge beats dropping a
  # legitimately in-flight action.
  @lock_timeout_ms 300_000

  # Re-tick cadence (game-time units) for a locked head, so the character keeps
  # checking for staleness even when {:done} never arrives. Normal locks clear
  # via {:done} (which schedules an immediate tick) long before this fires, so
  # it only has an effect in the lost-round-trip case.
  @lock_poll_interval 0.1

  def jason(), do: []

  typedstruct enforce: true do
    field(:virtual_position, integer() | nil)
    field(:queue, %Queue{})
  end

  def new() do
    %ActionQueue{
      virtual_position: nil,
      queue: Queue.new()
    }
  end

  def set_virtual_position(%ActionQueue{} = state, virtual_position) do
    %{state | virtual_position: virtual_position}
  end

  def add(%ActionQueue{} = state, action, target) do
    add(%{state | virtual_position: target}, action)
  end

  def add(%ActionQueue{} = state, action) do
    %{state | queue: Queue.insert(state.queue, Action.new(action))}
  end

  def set_virtual_position_and_clear(%ActionQueue{} = state) do
    if ActionQueue.empty?(state) do
      state
    else
      {%Action{} = action, _queue} = Queue.pop(state.queue)

      ActionQueue.new()
      |> set_virtual_position(action.data["target"])
    end
  end

  @doc "replaces the first item of the queue with a new item"
  def replace_front(%ActionQueue{queue: queue} = state, item) do
    {_discarded_action, queue} = Queue.pop(queue)
    %{state | queue: Queue.insert_front(queue, item)}
  end

  @doc "replaces queue content with `new_items` and reset virtual_position"
  def replace_queue([]),
    do: ActionQueue.new()

  def replace_queue(new_items) do
    last_item = List.last(new_items)

    queue =
      ActionQueue.new()
      |> set_virtual_position(last_item.data["target"])

    %{queue | queue: Queue.new(new_items)}
  end

  def skip_initial_lock(nil), do: nil

  def skip_initial_lock(%ActionQueue{} = state) do
    case Queue.pop(state.queue) do
      {%Action{type: :locked}, queue} ->
        %{state | queue: queue}

      _ ->
        state
    end
  end

  @doc "(unlocks if necessary, then) removes current action"
  def abort_action(%ActionQueue{} = state) do
    case Queue.pop(state.queue) do
      {nil, queue} -> %{state | queue: queue}
      {%Action{type: :locked}, queue} -> abort_action(%{state | queue: queue})
      {%Action{}, queue} -> %{state | queue: queue}
    end
  end

  def clear_after(%ActionQueue{} = state, index) do
    Queue.to_list(state.queue)
    |> Enum.take(index)
    |> ActionQueue.replace_queue()
  end

  def lock(%ActionQueue{} = state, locked_at) do
    lock_action = %{Action.new({:locked, %{lock: true}, 100}) | started_at: locked_at}
    queue = Queue.insert_front(state.queue, lock_action)
    %{state | queue: queue}
  end

  def unlock(%ActionQueue{} = state) do
    {%Action{type: :locked}, queue} = Queue.pop(state.queue)
    %{state | queue: queue}
  end

  def process_next_action(%ActionQueue{} = state, time_since_last_tick, cumulated_pauses) do
    {action, popped_queue} = Queue.pop(state.queue)

    cond do
      is_nil(action) ->
        :empty

      action.type == :locked ->
        if lock_expired?(action, cumulated_pauses),
          do: :lock_expired,
          else: :queue_locked

      is_nil(action.started_at) ->
        updated_action = Action.start(action, cumulated_pauses)
        {:to_start, action, replace_front(state, updated_action)}

      is_number(action.remaining_time) ->
        case Action.compute_remaining_time(action, time_since_last_tick, cumulated_pauses) do
          {:start, updated_action} ->
            {:to_start, updated_action, replace_front(state, updated_action)}

          {:unfinished, updated_action} ->
            {:ongoing, updated_action, replace_front(state, updated_action)}

          {:finished, _finished_x_ms_ago} ->
            {:to_finish, action, %{state | queue: popped_queue}}
        end

      true ->
        # Half-stamped action: `started_at` set but duration never resolved
        # — the start hook crashed (or the agent restarted) between stamping
        # and `reset_time` (see Action.rebase_started_at's doc, the
        # 2026-06-15 frozen-agents incident). Unrecoverable by waiting: no
        # hook is in flight (that would be a :locked head). Abort it so the
        # character loses one order instead of jamming forever.
        Logger.warning("aborting unprocessable action #{inspect(action)}")
        {:to_abort, action, %{state | queue: popped_queue}}
    end
  end

  def get_next_action_remaining_time(state) do
    action = Queue.peek(state.queue)

    cond do
      is_nil(action) ->
        :never

      action.type == :locked ->
        # Re-tick soon so a stale lock (lost orchestrator round-trip) gets
        # detected and recovered instead of sitting forever. A live lock is
        # cleared by {:done} (immediate tick) well before this matters.
        @lock_poll_interval

      is_number(action.remaining_time) ->
        action.remaining_time

      true ->
        0.1
    end
  end

  # A lock with no timestamp predates the self-heal mechanism (or rode in on a
  # snapshot that lost it) — treat as stale. Otherwise compare the lock's
  # pause-adjusted wall-clock age to the timeout. Time.now/1 subtracts
  # cumulated_pauses, so a paused engine doesn't age locks.
  defp lock_expired?(%Action{started_at: nil}, _cumulated_pauses), do: true

  defp lock_expired?(%Action{started_at: locked_at}, cumulated_pauses) do
    Instance.Time.Time.now(cumulated_pauses) - locked_at > @lock_timeout_ms
  end

  def empty?(state) do
    Queue.empty?(state.queue)
  end

  def map(state, fun) when is_function(fun, 1) do
    %{state | queue: Queue.map(state.queue, fun)}
  end
end
