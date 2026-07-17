defmodule RC.ShutdownSnapshots do
  @moduledoc """
  Snapshots every live game instance when the node shuts down
  gracefully — SIGTERM, `systemctl stop/restart` (including restarts
  propagated through unit dependencies), `:init.stop`, deploys.

  ## Why

  In-memory instance state does not survive a BEAM restart on a
  single-node deployment: the Horde-CRDT handoff the agents write in
  their terminate callbacks dies with the node. Historically the only
  shutdown-time persistence was the deploy script's *pre-stop* rpc —
  protection bolted onto one stop path. Every other stop (a stray
  `systemctl restart`, an operator mistake, a host reboot) lost up to
  one autosave interval (~15–19 min) of gameplay. This module makes
  the invariant hold for ALL graceful stops: the BEAM does not exit
  before running instances are snapshotted.

  ## How

  Started LAST in `RC.Application`'s children, so at shutdown it
  terminates FIRST — while `Game`, `RC.Repo`, and the rest of the
  tree are still fully alive. `terminate/2` walks every instance the
  DB considers running/paused that actually has live agents, and runs
  the same `stop → make_snapshot` sequence the periodic autosave uses
  (skipping the restart — the node is going down). Instances are
  snapshotted sequentially; a failure on one never blocks the others.

  The child spec's `shutdown:` budget and systemd's `TimeoutStopSec`
  (see deploy/systemd/rc.service) are sized so a slow snapshot is not
  killed mid-write. A SIGKILL still bypasses everything — that's what
  the periodic autosave remains for.

  ## Escape hatch

  If snapshotting ITSELF ever misbehaves (hangs, corrupt writes) and
  is blocking shutdowns, set `RC_SHUTDOWN_SNAPSHOT_DISABLED=1` in the
  environment and restart: this module then no-ops. Also disabled in
  `:test`.
  """

  use GenServer

  require Logger

  import Ecto.Query

  # Generous per-call budgets, mirroring the periodic autosave's. The
  # supervisor-facing total budget lives in child_spec/1 below.
  @stop_timeout 120_000
  @snapshot_timeout 300_000

  @disable_env "RC_SHUTDOWN_SNAPSHOT_DISABLED"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # The whole point is doing work in terminate/2 — give it room.
      # Must stay below systemd's TimeoutStopSec (630s in the unit).
      shutdown: 600_000
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(reason, _state) do
    if enabled?() do
      ids = live_instance_ids()

      if ids != [] do
        Logger.warning(
          "[RC.ShutdownSnapshots] node stopping (#{inspect(reason)}) — snapshotting #{length(ids)} instance(s): #{inspect(ids)}"
        )

        Enum.each(ids, &snapshot_one/1)
      end
    end

    :ok
  end

  ## Internals

  defp enabled? do
    Application.get_env(:rc, :environment) != :test and
      System.get_env(@disable_env) in [nil, "", "0", "false"]
  end

  # Instances the DB considers in-play AND that actually have live
  # agents on this node. Bot-only instances are included — their
  # progress is worth the file too, and the boot path decides how to
  # bring each kind back.
  defp live_instance_ids do
    from(i in RC.Instances.Instance,
      where: i.state in ["running", "paused"],
      select: i.id
    )
    |> RC.Repo.all()
    |> Enum.filter(fn id -> Instance.Manager.get_status(id) in [:running, :instantiated] end)
  rescue
    e ->
      Logger.error("[RC.ShutdownSnapshots] instance scan failed: #{inspect(e)}")
      []
  end

  # Same sequence as the periodic autosave in Instance.Time, minus the
  # restart: stop ticking so the dump is consistent, then snapshot.
  defp snapshot_one(instance_id) do
    case Instance.Manager.call(instance_id, :stop, @stop_timeout) do
      {:ok, :stopped, _} -> :ok
      other -> Logger.warning("[RC.ShutdownSnapshots] stop of ##{instance_id} returned #{inspect(other)}")
    end

    case Instance.Manager.call(instance_id, :make_snapshot, @snapshot_timeout) do
      {:ok, _snapshot} ->
        Logger.warning("[RC.ShutdownSnapshots] snapshotted instance ##{instance_id}")

      other ->
        Logger.error("[RC.ShutdownSnapshots] snapshot of ##{instance_id} FAILED: #{inspect(other)}")
    end
  rescue
    e ->
      Logger.error("[RC.ShutdownSnapshots] snapshot of ##{instance_id} crashed: #{inspect(e)}")
  catch
    kind, payload ->
      Logger.error("[RC.ShutdownSnapshots] snapshot of ##{instance_id} exited: #{inspect({kind, payload})}")
  end
end
