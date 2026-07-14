defmodule RC.InstanceBootRestore do
  @moduledoc """
  At rc.service boot, restores real-player instances that were alive
  at the previous shutdown from their most recent snapshot.

  Counterpart to `RC.ShutdownSnapshots`: together they make a plain
  `systemctl restart rc.service` self-healing — snapshot on the way
  down, restore on the way up — instead of requiring the deploy
  script's out-of-band rpc dance or manual operator recovery.

  ## Candidate selection

  `RC.Instances.update_instances_state_if_needed(true)` (the boot
  status fixer, sequenced before this task) rewrites instances the DB
  thought were running/paused to "not_running" when their agents are
  gone. We restore exactly the instances that fixer just demoted:

    * current state "not_running", AND
    * that not_running row was written within the last few minutes
      (i.e. by THIS boot — an instance an admin stopped last week has
      an old row and stays down), AND
    * the state before it was "running" or "paused", AND
    * not bot-only (those rebuild from model via
      `RC.BotOnlyInstanceRestart` — cheaper and always safe), AND
    * a snapshot exists.

  Restoration reuses `RC.Instances.restore_instance/2`, whose
  running/paused branches are the battle-tested snapshot-load path.
  The guard on previous-state protects us from its known
  CaseClauseError on maintenance-state history.

  Escape hatch: set `RC_BOOT_RESTORE_DISABLED=1` to keep the old
  manual behavior. Also skipped in `:test`.
  """

  import Ecto.Query

  require Logger

  @disable_env "RC_BOOT_RESTORE_DISABLED"

  # A not_running row older than this predates the current boot and
  # means "an operator stopped this on purpose" — leave it down.
  @boot_window_minutes 10

  def run do
    if enabled?() do
      # Snapshot deserialization uses safe binary_to_term, which
      # rejects atoms not yet interned in this VM. Releases preload
      # every module at boot (embedded mode), but dev's interactive
      # mode loads lazily — and even a release is safer with this
      # belt-and-braces. Load the app's modules so their atoms exist
      # before any snapshot is decoded.
      preload_modules()

      candidates = candidate_ids()

      if candidates == [] do
        Logger.info("[boot_restore] no real-player instances to restore")
      else
        Logger.warning("[boot_restore] restoring #{length(candidates)} instance(s): #{inspect(candidates)}")
        Enum.each(candidates, &restore_one/1)
      end
    else
      Logger.info("[boot_restore] disabled — skipping")
    end
  end

  @doc """
  Instance ids eligible for boot restore. Public for tests.
  """
  def candidate_ids(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@boot_window_minutes * 60, :second)

    from(i in RC.Instances.Instance,
      where: i.state == "not_running" and i.is_bot_only == false,
      select: i.id
    )
    |> RC.Repo.all()
    |> Enum.filter(fn id ->
      fresh_shutdown?(id, cutoff) and has_snapshot?(id) and
        Instance.Manager.get_status(id) == :not_instantiated
    end)
  end

  # True when the newest instance_states row is a not_running written
  # inside the boot window AND the state before it was running/paused.
  defp fresh_shutdown?(instance_id, cutoff) do
    rows =
      from(s in RC.Instances.InstanceState,
        where: s.instance_id == ^instance_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: 2,
        select: {s.state, s.inserted_at}
      )
      |> RC.Repo.all()

    case rows do
      # inserted_at is utc_datetime_usec — already a DateTime.
      [{"not_running", %DateTime{} = stamped_at}, {previous, _}] when previous in ["running", "paused"] ->
        DateTime.compare(stamped_at, cutoff) == :gt

      _ ->
        false
    end
  end

  defp has_snapshot?(instance_id), do: RC.InstanceSnapshots.last(instance_id) != nil

  defp restore_one(instance_id) do
    instance = RC.Instances.get_instance(instance_id)

    case RC.Instances.restore_instance(instance, instance.account_id) do
      {:ok, _} ->
        Logger.warning("[boot_restore] restored instance ##{instance_id} (#{instance.name})")

      other ->
        Logger.error("[boot_restore] restore of ##{instance_id} FAILED: #{inspect(other)}")
    end
  rescue
    e ->
      Logger.error("[boot_restore] restore of ##{instance_id} crashed: #{inspect(e)}")
  end

  defp enabled? do
    Application.get_env(:rc, :environment) != :test and
      System.get_env(@disable_env) in [nil, "", "0", "false"]
  end

  defp preload_modules do
    {time_us, _} =
      :timer.tc(fn ->
        # ALL loaded applications, not just :rc — agent state embeds
        # dependency structs (Horde registries, MerkleMap, queues…)
        # whose module atoms must also be interned for the safe
        # decode. Verified: :rc-only preload still trips
        # :unsafe_snapshot; the full sweep passes.
        for {app, _desc, _vsn} <- Application.loaded_applications() do
          app |> Application.spec(:modules) |> Kernel.||([]) |> Enum.each(&Code.ensure_loaded/1)
        end
      end)

    # warning-level on purpose: dev's logger level hides :info, and an
    # operator debugging a failed boot restore needs to see whether the
    # preload ran (see the :unsafe_snapshot decode gotcha in the run/0
    # comment).
    Logger.warning("[boot_restore] preloaded modules of all loaded apps in #{div(time_us, 1000)}ms")
  rescue
    e -> Logger.warning("[boot_restore] module preload failed (continuing): #{inspect(e)}")
  end
end
