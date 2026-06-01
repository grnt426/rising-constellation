defmodule Portal.ChannelWatcher do
  @moduledoc """
  Watches Phoenix channel processes and runs a registered leave
  callback when one dies.

  Stage 7 cluster D rewrite (F4 + F20):

    * **F4** — the previous implementation used `Process.link/1`,
      which is symmetric: a watcher crash would take every linked
      channel down with it, kicking every connected player off the
      node. We now use `Process.monitor/1`, which is asymmetric: the
      watcher learns about channel deaths via `:DOWN`, but its own
      crash is invisible to the channels (they just lose their leave
      callback for that session).

    * **F20** — the previous implementation spawned the leave
      callback via `Task.start_link/1` with no error logging, so any
      raise inside a callback (e.g. an `update_client_status`
      cascading off a dead Player.Agent) was silently swallowed and
      the player's `connected` status would leak forever. We now
      dispatch the callback through `RC.TaskSupervisor` with a
      `try/rescue/catch` wrapper that logs the failure.

  We also added a periodic alive sweep so monotonically-growing
  `state.channels` from missed `:DOWN` messages (e.g. on partition)
  can't leak memory indefinitely.
  """
  use GenServer

  require Logger

  # 60s sweep is conservative; channels normally tear down in seconds
  # via :DOWN. The sweep is the belt-and-suspenders path.
  @sweep_interval 60_000

  ## Client API

  def monitor(server_name, pid, mfa) do
    GenServer.call(server_name, {:monitor, pid, mfa})
  end

  def demonitor(server_name, pid) do
    GenServer.call(server_name, {:demonitor, pid})
  end

  ## Server API

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @impl true
  def init(_) do
    # No more Process.flag(:trap_exit, true): we don't link to any
    # pid anymore, so trap_exit had no work to do. Removing it also
    # closes the Stage 7 F19/F26 hazard where an unsolicited :EXIT
    # message could land here and hit a missing handle_info clause.
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, %{channels: Map.new(), refs: Map.new()}}
  end

  @impl true
  def handle_call({:monitor, pid, mfa}, _from, state) do
    ref = Process.monitor(pid)

    state =
      state
      |> Map.update!(:channels, &Map.put(&1, pid, mfa))
      |> Map.update!(:refs, &Map.put(&1, ref, pid))

    {:reply, :ok, state}
  end

  def handle_call({:demonitor, pid}, _from, state) do
    case Map.fetch(state.channels, pid) do
      :error ->
        {:reply, :ok, state}

      {:ok, _mfa} ->
        # Find the ref(s) pointing at this pid and demonitor them.
        # In practice there's at most one because monitor/3 is called
        # once per channel, but we sweep all matches defensively.
        {refs_for_pid, refs_other} =
          Enum.split_with(state.refs, fn {_r, p} -> p == pid end)

        Enum.each(refs_for_pid, fn {r, _p} -> Process.demonitor(r, [:flush]) end)

        state = %{
          state
          | channels: Map.delete(state.channels, pid),
            refs: Map.new(refs_other)
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.channels, pid) do
      :error ->
        # Stale ref (we already removed this pid via demonitor or
        # sweep). Just clean up the ref index.
        {:noreply, %{state | refs: Map.delete(state.refs, ref)}}

      {:ok, {mod, func, args}} ->
        # Stage 7 F20: dispatch the leave callback through
        # RC.TaskSupervisor and wrap it so a raise is logged instead
        # of silently swallowed. The Task is :temporary so it does
        # not get restarted on failure.
        Task.Supervisor.start_child(
          RC.TaskSupervisor,
          fn -> run_leave_callback(mod, func, args) end,
          restart: :temporary
        )

        state = %{
          state
          | channels: Map.delete(state.channels, pid),
            refs: Map.delete(state.refs, ref)
        }

        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    # Stage 7 F4 follow-on. Prune any pids that died without sending
    # us :DOWN (network partition, distributed node loss, etc.) so
    # the maps don't grow without bound.
    {alive_channels, alive_refs, removed} =
      Enum.reduce(state.channels, {%{}, state.refs, 0}, fn {pid, mfa}, {ch_acc, refs_acc, removed} ->
        if Process.alive?(pid) do
          {Map.put(ch_acc, pid, mfa), refs_acc, removed}
        else
          dead_refs =
            refs_acc
            |> Enum.filter(fn {_r, p} -> p == pid end)
            |> Enum.map(fn {r, _p} -> r end)

          Enum.each(dead_refs, fn r -> Process.demonitor(r, [:flush]) end)

          refs_acc = Enum.reduce(dead_refs, refs_acc, fn r, acc -> Map.delete(acc, r) end)
          {ch_acc, refs_acc, removed + 1}
        end
      end)

    if removed > 0 do
      Logger.info("ChannelWatcher swept stale channels",
        removed: removed,
        remaining: map_size(alive_channels)
      )
    end

    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, %{state | channels: alive_channels, refs: alive_refs}}
  end

  # Anything else (stray PubSub, debug Process.send, etc.) — log and
  # ignore rather than crashing.
  def handle_info(other, state) do
    Logger.debug("ChannelWatcher ignored unexpected message", message: inspect(other))
    {:noreply, state}
  end

  defp run_leave_callback(mod, func, args) do
    try do
      apply(mod, func, args)
    rescue
      err ->
        Logger.error("ChannelWatcher leave callback raised",
          module: mod,
          function: func,
          args: inspect(args),
          error: Exception.message(err),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )
    catch
      kind, reason ->
        Logger.error("ChannelWatcher leave callback exited",
          module: mod,
          function: func,
          args: inspect(args),
          kind: kind,
          reason: inspect(reason)
        )
    end
  end
end
