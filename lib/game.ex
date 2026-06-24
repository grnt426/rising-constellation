defmodule Game do
  use Supervisor

  require Logger

  @self __MODULE__

  def start_link(_opts) do
    Supervisor.start_link(@self, :ok, name: @self)
  end

  @impl true
  def init(:ok) do
    spawn(fn -> Portal.Config.init_config() end)
    # Stage 7 F14: explicit max_restarts/max_seconds. OTP defaults
    # (3/5s) are sized for small static trees; this supervisor sits
    # above Horde.Registry + Horde.DynamicSupervisor + the cluster
    # connector, and a transient blip during cluster join would
    # otherwise consume the entire budget. 10 restarts in 60s gives
    # operational headroom without masking real cascades.
    Supervisor.init(child_spec_list(),
      strategy: :one_for_one,
      shutdown: 10_000,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  def child_spec_list do
    [
      {Horde.Registry, name: Game.Registry, keys: :unique, members: :auto, shutdown: 60_000},
      {Horde.DynamicSupervisor,
       [
         name: Game.Supervisor,
         strategy: :one_for_one,
         distribution_strategy: Horde.UniformQuorumDistribution,
         shutdown: 10_000,
         members: :auto,
         # Stage 7 F14: explicit budget for the Horde supervisor that
         # owns every Instance.Supervisor in the cluster. 50 restarts
         # in 60s allows tens of instances to recycle without bringing
         # the whole quorum down.
         max_restarts: 50,
         max_seconds: 60
       ]},
      %{
        id: Game.ClusterConnector,
        restart: :transient,
        start: {Task, :start_link, [fn -> Horde.DynamicSupervisor.wait_for_quorum(Game.Supervisor, 30_000) end]}
      }
    ]
    |> maybe_start_cluster_supervisor(Application.get_env(:rc, :environment))
  end

  def get_pid(_, attempts \\ 0)

  def get_pid(name_tuple, attempts) do
    result = Horde.Registry.lookup(Game.Registry, name_tuple)

    cond do
      length(result) > 0 ->
        [{pid, _} | _] = result
        {:ok, pid}

      attempts > 1 ->
        Process.sleep(200)
        get_pid(name_tuple, attempts - 1)

      true ->
        {:error, :process_not_found}
    end
  end

  # Deterministic, process-local RNG for the headless battle simulator
  # (Sim.Arena). The :fast_prod clause below reseeds from OS entropy on
  # *every* draw — non-reproducible and slow. This threads one seeded
  # :rand state through the process dictionary, so a whole battle is
  # reproducible from a single seed (set by Sim.Arena before the fight)
  # and draws are cheap. No GenServer hop → battles parallelize across
  # schedulers with no shared rand-process contention.
  def call(:sim, :rand, :master, action) do
    rand_state = Process.get(:rc_sim_rand_state) || :rand.seed_s(:exrop)

    {_, result, new_state} =
      Instance.Rand.Agent.on_call(action, nil, %{data: %{rand_state: rand_state}})

    Process.put(:rc_sim_rand_state, new_state.data.rand_state)
    result
  end

  @doc """
  TODO
  """
  def call(instance_atom, :rand, :master, action) when is_atom(instance_atom) do
    state = %{data: %{rand_state: :rand.seed(:exrop)}}
    {_, result, _} = Instance.Rand.Agent.on_call(action, nil, state)

    result
  end

  def call(instance_atom, _type, _agent_id, _action) when is_atom(instance_atom) do
    Logger.error("module not available in virtual instance")
    {:error, :process_not_found}
  end

  @doc """
  Call the pid for eg. `{12, :stellar_system, 44}` (instance 12, StellarSystem.Agent, id 44) with
  action = action. Log when process not found. Defaults to only 1 attempt at getting the PID.
  """
  def call(instance_id, type, agent_id, action, attempts \\ 2, timeout \\ 5_000) do
    do_call(instance_id, type, agent_id, action, true, attempts, timeout)
  end

  @doc """
  Same as `Game.call/4` but does *not* log when process not found.

  Stage 7 F24: optional `timeout` argument (default 5_000ms) lets
  per-row admin listings — see `RC.Instances.put_instance_supervisor_status/1`
  — bound their per-call wait to a small budget so one hung Time.Agent
  does not 500 the entire instance list.
  """
  def call_no_log(instance_id, type, agent_id, action, attempts \\ 2, timeout \\ 5_000) do
    do_call(instance_id, type, agent_id, action, false, attempts, timeout)
  end

  defp do_call(instance_id, type, agent_id, action, log_failure, attempts, timeout) do
    case get_pid({instance_id, type, agent_id}, attempts) do
      {:ok, _pid} ->
        safe_call(instance_id, type, agent_id, action, log_failure, timeout)

      {:error, :process_not_found} ->
        if log_failure do
          Logger.error("process_not_found in call",
            instance_id: instance_id,
            type: type,
            agent_id: agent_id,
            action: action
          )
        end

        :process_not_found
    end
  end

  # Stage 7 cluster C (F6 high). Wrap GenServer.call so a crashed
  # callee returns {:error, :callee_crashed} (or :callee_timeout) to
  # the caller instead of cascading an :exit signal up the chain. The
  # Stage 7 audit (docs/stage-7-report.md) found 232 cross-agent
  # Game.call sites with zero `catch :exit` wrappers — meaning one
  # crashed leaf could topple the entire Game.call chain into the
  # Phoenix channel process. This containment lets every caller
  # handle the failure gracefully (with the existing case clauses
  # already in place for `:process_not_found`).
  defp safe_call(instance_id, type, agent_id, action, log_failure, timeout) do
    try do
      GenServer.call(via_tuple({instance_id, type, agent_id}), action, timeout)
    catch
      :exit, {:noproc, _} ->
        # Race: process disappeared between get_pid and call. Treated
        # the same way as the up-front lookup miss.
        if log_failure do
          Logger.error("process_not_found in call (race)",
            instance_id: instance_id,
            type: type,
            agent_id: agent_id,
            action: action
          )
        end

        :process_not_found

      :exit, {:timeout, _} ->
        if log_failure do
          Logger.error("callee_timeout in call",
            instance_id: instance_id,
            type: type,
            agent_id: agent_id,
            action: action
          )
        end

        {:error, :callee_timeout}

      :exit, reason ->
        # Any other exit reason (callee crashed, was shutdown mid-call,
        # nodedown, etc.). Crucially we do NOT re-raise — that would be
        # the Stage 7 cascade.
        if log_failure do
          Logger.error("callee_crashed in call",
            instance_id: instance_id,
            type: type,
            agent_id: agent_id,
            action: action,
            reason: inspect(reason)
          )
        end

        {:error, :callee_crashed}
    end
  end

  def cast(instance_id, type, agent_id, action) do
    case get_pid({instance_id, type, agent_id}) do
      {:ok, _pid} ->
        GenServer.cast(via_tuple({instance_id, type, agent_id}), action)

      {:error, :process_not_found} ->
        Logger.error("process_not_found in cast",
          instance_id: instance_id,
          type: type,
          agent_id: agent_id,
          action: action
        )

        :process_not_found
    end
  end

  def via_tuple(name) do
    {:via, Horde.Registry, {Game.Registry, name}}
  end

  defp maybe_start_cluster_supervisor(children, :test), do: children

  defp maybe_start_cluster_supervisor(children, _) do
    [{RC.ClusterSupervisor, Application.get_env(:libcluster, :topologies)} | children]
  end
end
