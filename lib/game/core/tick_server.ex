defmodule Core.TickServer do
  # Macros for modules using `TickServer`

  defmacro __using__(_params) do
    quote do
      require Logger

      use GenServer
      use Util.TickDecorator

      @before_compile Core.TickServer

      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state, {:continue, :load_state}}
      end

      def handle_continue(:load_state, state) do
        {:noreply, load_state(state)}
      end

      # Runtime speed cheat (Instance.Manager {:cheat_set_speedup, _} fan-out).
      # Handled here — ahead of the generic on_call dispatch — so every
      # TickServer agent supports it without touching each module. Flush the
      # in-flight window at the OLD factor first (wall time already elapsed
      # converts at the rate it actually ran), then swap the factor and
      # re-arm — the previously scheduled :tick was computed with the old
      # factor and could otherwise sit hours in the wall-clock future.
      def handle_call({:cheat_set_tick_factor, new_factor}, _from, state)
          when is_number(new_factor) and new_factor > 0 do
        state =
          if state.tick.running? do
            state = next_tick(state)
            state = %{state | tick: %{state.tick | factor: new_factor}}
            next_tick(state)
          else
            %{state | tick: %{state.tick | factor: new_factor}}
          end

        {:reply, :ok, state}
      end

      def handle_call(arg, from, state) do
        state = if arg == :stop, do: next_tick(state), else: state
        result = on_call(arg, from, state)

        case result do
          {:reply, _reply, new_state} -> new_state
          {:reply, _reply, new_state, _arg2} -> new_state
          {:noreply, new_state} -> new_state
          {:noreply, new_state, _arg2} -> new_state
          {:stop, _reason, _reply, new_state} -> new_state
          {:stop, _reason, new_state} -> new_state
        end
        |> save_state()

        result
      end

      def handle_cast(request, state) do
        result = on_cast(request, state)

        case result do
          {:noreply, new_state} -> new_state
          {:noreply, new_state, _arg2} -> new_state
          {:stop, _reason, new_state} -> new_state
        end
        |> save_state()

        result
      end

      def handle_info(msg, state) do
        result = on_info(msg, state)

        case result do
          {:noreply, new_state} -> new_state
          {:noreply, new_state, _arg2} -> new_state
          {:stop, _reason, new_state} -> new_state
        end
        |> save_state()

        result
      end

      def terminate(:shutdown, %{kill: true}) do
        # process is terminated by the manager, don't save its state
        :ok
      end

      def terminate(:normal, state), do: Core.TickServer.graceful_terminate(state, __MODULE__)
      def terminate(:shutdown, state), do: Core.TickServer.graceful_terminate(state, __MODULE__)
      def terminate({:shutdown, _}, state), do: Core.TickServer.graceful_terminate(state, __MODULE__)

      def terminate(reason, state) do
        # Stage 7 cluster B (F11 critical + F12 high). On a CRASH reason
        # (anything other than :normal/:shutdown/{:shutdown,_}) we
        # deliberately do NOT save the dying state for handoff. The
        # Stage 7 audit (docs/stage-7-report.md) showed that writing
        # the crash-state back to Horde.Registry was a guaranteed
        # poison pill: load_state/1 retrieves and replays the exact
        # same value on restart, the agent crashes again, the cycle
        # repeats forever, and the saved state replicates cluster-wide
        # via the Horde DeltaCRDT so even a node replacement does not
        # clear it. We also skip the 10s Process.sleep — its sole job
        # is to give the Horde CRDT time to replicate a graceful save,
        # but on a crash there is nothing to replicate, and sleeping
        # masks the supervisor's max_restarts circuit-breaker window
        # (5s default, 10s sleep ⇒ breaker never fires).
        Core.TickServer.discard_crash_state(reason, state, __MODULE__)
      end

      def start_link(opts), do: Core.TickServer.start_link(opts, __MODULE__)

      def next_tick(%{tick: %{running?: false}} = state), do: state

      def next_tick(state) do
        {state, module} = do_next_tick(state, Core.Tick.delta(state.tick))
        next_tick = module.compute_next_tick_interval(state.data)
        next_tick = Core.Tick.unit_time_to_millisecond(state.tick, next_tick)

        # This will print every tick_servers' tick
        # print_tick_data(state, next_tick, [])

        # This will print only player and stellar_systems tick_servers' tick
        # print_tick_data(state, next_tick, [:player, :stellar_system])

        %{state | tick: Core.Tick.next(state.tick, next_tick)}
      end

      def print_tick_data(state, next_tick, only) do
        if Enum.empty?(only) or Enum.any?(only, fn type -> state.type == type end) do
          process_name = "#{state.type}:#{state.agent_id}"

          next_tick =
            if next_tick == :never,
              do: ":never",
              else: "in #{next_tick / 1000}s"

          Logger.info("#{String.pad_trailing(process_name, 25)} next tick #{next_tick}")
        end
      end

      defp load_state(state) do
        # try loading handoff data (load it if it's there)
        name_tuple = Core.GenState.registry_name(state)
        Horde.Registry.register(Game.Registry, name_tuple, self())

        case Data.GenServerState.retrieve_delete(name_tuple) do
          # A crash left a recovery marker (see discard_crash_state). Recover
          # this agent's domain data from the latest instance snapshot rather
          # than falling back to the frozen join-time genesis child-spec args
          # (which would wipe the player back to starting resources).
          {:ok, %{state: :crash_recover_from_snapshot}} ->
            Core.TickServer.recover_from_snapshot(state)

          {:ok, %{state: state_to_restore}} ->
            state_to_restore

          :error ->
            state
        end
      end

      defp save_state(state) do
        # Core.GenState.registry_name(new_state)
        # |> Data.GenServerState.save(new_state, __MODULE__)
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defdelegate on_call(message, from, state), to: Core.TickServer
      defdelegate on_cast(request, state), to: Core.TickServer
      defdelegate on_info(msg, state), to: Core.TickServer
    end
  end

  # Client

  @doc """
  Graceful terminate path used by every TickServer-using agent for
  `:normal`, `:shutdown`, and `{:shutdown, _}` reasons. Saves handoff
  state into the Horde Registry CRDT and sleeps 10s so the saved state
  has time to replicate before the process actually exits.
  """
  def graceful_terminate(state, module) do
    name_tuple = Core.GenState.registry_name(state)
    Horde.Registry.unregister(Game.Registry, name_tuple)

    # Headless (in-memory, throwaway) instances have nothing worth handing
    # off — and the save + replication sleep is the dominant cost of tearing
    # down a finished headless game (hundreds of agents × up to 10s each,
    # bounded only by the supervisor's shutdown timeout).
    unless Instance.Mutators.headless?(Map.get(state, :instance_id)) do
      Data.GenServerState.save(name_tuple, state, module)
      Process.sleep(10_000)
    end
  end

  @doc """
  Crash terminate path. Stage 7 cluster B fix: do NOT write the dying
  state back to the Horde Registry — that would create a guaranteed
  crash loop because `load_state/1` would replay the same crash-state
  on restart. Also do not sleep, so the supervisor's max_restarts
  budget can accumulate. Best-effort unregisters the live name and
  clears any stale saved entry from a prior graceful save.
  """
  def discard_crash_state(reason, state, module) do
    safe_apply(fn ->
      require Logger

      Logger.warning("TickServer crash — discarding state, not saving for handoff",
        reason: inspect(reason),
        module: module,
        state_type: Map.get(state, :type),
        agent_id: Map.get(state, :agent_id),
        instance_id: Map.get(state, :instance_id)
      )
    end)

    safe_apply(fn ->
      name_tuple = Core.GenState.registry_name(state)
      Horde.Registry.unregister(Game.Registry, name_tuple)
      # Do NOT save the dying state for handoff — replaying it on restart was
      # the Stage-7 poison pill. But dropping *everything* reverted the agent
      # to its frozen join-time genesis child-spec args, wiping all progress
      # (see the instance-49 player-reset incident). Instead leave a small
      # marker so the restart recovers this agent's data from the latest
      # instance snapshot. The marker is consumed (retrieve_delete) on the
      # very next restart, and snapshot states are older, tick-tested good
      # states — so this cannot poison-loop the way replaying the crash-state
      # did.
      Data.GenServerState.save(name_tuple, :crash_recover_from_snapshot, module)
    end)

    :ok
  end

  @doc """
  Recover an agent's domain `data` from the most recent instance snapshot.

  Used by the crash-restart path (`load_state`, when it finds a
  `:crash_recover_from_snapshot` marker) so a single agent crash reverts to
  the last autosave snapshot rather than to the frozen join-time genesis
  state. Keeps the freshly-built GenState wrapper (tick/channel/speed) and
  only swaps in the recovered `data`. Falls back to the given genesis state
  if no snapshot slice can be loaded. Never raises.
  """
  def recover_from_snapshot(state) do
    with {instance_id, type, agent_id} <- Core.GenState.registry_name(state),
         {:ok, data} <- snapshot_data(instance_id, type, agent_id) do
      safe_apply(fn ->
        require Logger

        Logger.warning("TickServer recovered agent from snapshot after crash",
          state_type: type,
          agent_id: agent_id,
          instance_id: instance_id
        )
      end)

      %{state | data: data}
    else
      _ ->
        safe_apply(fn ->
          require Logger

          Logger.error("TickServer crash-recovery found no snapshot slice — starting from genesis",
            state: inspect(Map.get(state, :type)),
            agent_id: inspect(Map.get(state, :agent_id)),
            instance_id: inspect(Map.get(state, :instance_id))
          )
        end)

        state
    end
  end

  # Pull one agent's snapshot slice ({type, agent_id}) out of the latest
  # instance snapshot. Guarded so a missing/corrupt snapshot yields :error
  # (→ genesis fallback) rather than raising inside the restart continue.
  defp snapshot_data(instance_id, type, agent_id) do
    with %{name: name} <- RC.InstanceSnapshots.last(instance_id),
         {:ok, %{agents_data: agents}} <- Util.Storage.load(name),
         %{state: %{data: data}} <-
           Enum.find(agents, fn
             %{state: %{type: ^type, agent_id: ^agent_id}} -> true
             _ -> false
           end) do
      {:ok, data}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Tiny helper: terminate callbacks must not themselves raise (raising
  # in terminate masks the original crash reason and can confuse the
  # supervisor). All Logger and Horde calls are wrapped.
  defp safe_apply(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  def start_link(opts, module) do
    state = Keyword.get(opts, :state)

    case GenServer.start_link(module, state, name: Game.via_tuple(Core.GenState.registry_name(state))) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> :ignore
    end
  end

  # SERVER - default implementations used by *.Agent,
  # these are called via defdelegate in case they are not already defined,
  # for instance Time.Agent defines {:start, …} so this {:start, …} won't get called

  def on_call({:start, cumulated_pauses}, _from, state),
    do: {:reply, :ok, %{state | tick: Core.Tick.start(%{state.tick | cumulated_pauses: cumulated_pauses})}}

  def on_call(:stop, _from, state),
    do: {:reply, :ok, %{state | tick: Core.Tick.stop(state.tick)}}

  def on_call(:get_full_state, _from, state),
    do: {:reply, state, state}

  # call this before terminating a process to ensure it does not get restarted
  def on_call(:prepare_kill, _from, state),
    do: {:reply, :ok, %{state | kill: true}}

  # insert dummy implementations of on_call/on_cast/on_info at the end of the module
  # otherwise we end up with e.g. `undefined function on_info/2` in cas the module
  # using TickServer does not contain an (e.g.) on_info/2
  def on_call(_arg, _from, _state), do: throw(:not_implemented)
  def on_cast(_request, _state), do: throw(:not_implemented)
  def on_info(_msg, _state), do: throw(:not_implemented)
end
