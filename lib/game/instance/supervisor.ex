defmodule Instance.Supervisor do
  @moduledoc """
  DynamicSupervisor supervising all processes of a single instance
  """

  use DynamicSupervisor

  require Logger

  @handoff_timeout 3_000

  def start_link(opts \\ []) do
    starter(opts, 20)
  end

  defp starter(_instance_id, 0), do: :ignore

  defp starter(opts, attempts) do
    instance_id = Keyword.get(opts, :id)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: Game.via_tuple({instance_id, :instance_supervisor})) do
      {:ok, pid} ->
        spawn(fn -> continue(instance_id, pid) end)
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        # when a node dies, the dynamic supervisor of each instance living on this node will stay reachable for a short while
        # so we keep trying to reach it a few times and we either give up (:ignore) or, if we cannot reach it anymore,
        # we start a new dynamic supervisor and hydrate it with the handoff data from the dying node
        Process.sleep(500)
        starter(opts, attempts - 1)
    end
  end

  @impl true
  def init(_opts) do
    # Stage 7 F14: explicit max_restarts/max_seconds. This supervisor
    # owns every per-instance agent (Player.Agent, Faction.Agent,
    # Character.Agent, StellarSystem.Agent, Galaxy.Agent, Time.Agent,
    # Rand.Agent, Victory.Agent, CharacterMarket.Agent,
    # ActionOrchestrator.Agent, Manager, Spatial.Supervisor) — for a
    # normal galaxy that is hundreds to thousands of permanent
    # children. The OTP default 3/5s budget made a single misbehaving
    # agent enough to take down the whole instance and cascade into
    # Game.Supervisor + Game + RC.Supervisor up to BEAM exit. 100
    # restarts in 60s gives genuine flapping protection while still
    # letting a real crash storm escalate to operators. The deeper
    # F1 topology split (per-aggregate sub-supervisors) is deferred —
    # see docs/stage-7-report.md.
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60
    )
  end

  defp continue(instance_id, supervisor_pid) do
    saved_states = Data.GenServerState.list(instance_id)

    if Enum.empty?(saved_states) do
      # Stage 7 F28-partial follow-on. The CRDT has no saved state for
      # an instance the supervisor is being asked to (re)start —
      # which happens after a hard BEAM crash that wiped the in-memory
      # Horde.Registry meta. If the DB still says the instance was
      # running or paused, the rehydration silently no-ops and the
      # admin's instance list shows it as `:not_instantiated` until
      # someone notices. Emit a CRITICAL log so operators are alerted
      # to the silent state loss.
      maybe_warn_on_empty_recovery(instance_id)
    else
      # Stage 7 F13: wrap the Manager start in try/rescue. If the
      # Manager genuinely can't start (corrupted opts, port collision,
      # etc.) we want to fail visibly rather than crash the spawn'd
      # `continue/2` task silently — that would leave the saved
      # entries in the CRDT and bring no recovery.
      try do
        {:ok, _manager_pid} = DynamicSupervisor.start_child(supervisor_pid, {Instance.Manager, id: instance_id})
      rescue
        e ->
          Logger.critical("Instance.Supervisor.continue: Manager start failed",
            instance_id: instance_id,
            error: Exception.message(e),
            stacktrace: Exception.format_stacktrace(__STACKTRACE__)
          )
      catch
        kind, reason ->
          Logger.critical("Instance.Supervisor.continue: Manager start exited",
            instance_id: instance_id,
            kind: kind,
            reason: inspect(reason)
          )
      end

      # waiting before hydrating, just to be sure all handoff data had enough time to reach us
      Process.sleep(@handoff_timeout)
    end

    saved_states = Data.GenServerState.list(instance_id)

    unless Enum.empty?(saved_states) do
      # Stage 7 F13. Each per-agent start is wrapped so a single bad
      # blob (one corrupted saved state, one module-allow-list
      # rejection, one Manager.create_from_snapshot raising) does NOT
      # abort the whole recovery loop. Without this guard, a single
      # poisoned entry would skip every later restore, leaving the
      # instance in a half-rehydrated state.
      restored_count =
        saved_states
        |> Enum.reduce(0, fn name_tuple, acc ->
          if safe_restore_one(supervisor_pid, name_tuple), do: acc + 1, else: acc
        end)

      Logger.debug("restored #{restored_count} of #{length(saved_states)} processes")
    end
  end

  defp safe_restore_one(supervisor_pid, name_tuple) do
    try do
      case Data.GenServerState.retrieve_delete(name_tuple) do
        {:ok, %{state: :crash_recover_from_snapshot}} ->
          # A hard BEAM restart caught a transient per-agent crash-recovery
          # marker (normally consumed on the immediate single-agent restart).
          # There is nothing to restore from the CRDT here; drop it. The
          # agent, if it still needs to exist, is rebuilt from the snapshot on
          # the normal boot path.
          Logger.warning("Instance.Supervisor.continue: dropping stale crash-recovery marker",
            name_tuple: inspect(name_tuple)
          )

          false

        {:ok, %{state: state, module: module}} ->
          result =
            if Enum.member?([Spatial.Supervisor, Spatial.Handoff], module) do
              DynamicSupervisor.start_child(supervisor_pid, {module, state})
            else
              DynamicSupervisor.start_child(supervisor_pid, {module, state: state})
            end

          case result do
            {:ok, _pid} ->
              true

            {:ok, _pid, _info} ->
              true

            :ignore ->
              true

            {:error, reason} ->
              Logger.error("Instance.Supervisor.continue: skipping poisoned saved state",
                name_tuple: inspect(name_tuple),
                reason: inspect(reason)
              )

              false
          end

        :error ->
          unless elem(name_tuple, 1) == :spatial_handoff do
            Logger.warning("Nothing to restore for #{inspect(name_tuple)}")
          end

          false
      end
    rescue
      e ->
        Logger.error("Instance.Supervisor.continue: restore raised, skipping",
          name_tuple: inspect(name_tuple),
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        # Drop the poisoned entry so the next continue/2 doesn't keep
        # tripping on it. This is the F13 escape hatch — without it a
        # single bad blob would re-poison every subsequent supervisor
        # restart in the chain.
        try do
          Data.GenServerState.delete(name_tuple)
        rescue
          _ -> :ok
        end

        false
    catch
      kind, reason ->
        Logger.error("Instance.Supervisor.continue: restore exited, skipping",
          name_tuple: inspect(name_tuple),
          kind: kind,
          reason: inspect(reason)
        )

        try do
          Data.GenServerState.delete(name_tuple)
        rescue
          _ -> :ok
        end

        false
    end
  end

  defp maybe_warn_on_empty_recovery(instance_id) do
    # We only care about instances that the DB believes should be
    # running. If the DB is also stopped/created/closed, an empty
    # CRDT is the expected state.
    try do
      case RC.Instances.get_instance(instance_id) do
        nil ->
          :ok

        %{state: state} when state in ["running", "paused", "maintenance"] ->
          Logger.critical(
            "Instance.Supervisor: empty saved-state on instance the DB still considers '#{state}' — " <>
              "in-memory state was lost across a hard BEAM restart and is not being recovered",
            instance_id: instance_id,
            db_state: state
          )

        _other ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  def get_pid(instance_id, attempts \\ 1), do: Game.get_pid({instance_id, :instance_supervisor}, attempts)
end
