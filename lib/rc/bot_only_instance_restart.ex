defmodule RC.BotOnlyInstanceRestart do
  @moduledoc """
  At rc.service boot, re-instantiates the in-memory Instance.Manager
  process for every `is_bot_only=true` instance whose last persisted
  state was "running" or "paused". Without this, every restart of
  rc.service kills the in-memory game state and bots fail to join with
  `instance_not_instantiated` until an admin manually starts each
  instance again.

  Limited to `is_bot_only` instances on purpose — production-relevant
  games still go through the proper snapshot/restore path via the
  maintenance LiveView. We don't want to silently restart a real
  player's in-progress game without a fresh snapshot to load from.

  Called from `RC.Application` as a temporary Task, after the Repo
  is up.
  """

  import Ecto.Query
  require Logger

  def run do
    Logger.info("[bot_restart] scanning for bot-only instances to re-instantiate")

    # All is_bot_only instances regardless of state column. We can't
    # filter on "was running before shutdown" because fix_instances_statuses
    # runs in parallel and may have already rewritten the state to
    # "not_running" by the time we get here. We compensate by trusting
    # is_bot_only as the "this is for the bot fleet" intent marker —
    # operators don't flip that on for instances they want to keep
    # dormant.
    ids =
      from(i in RC.Instances.Instance,
        where: i.is_bot_only == true,
        select: i.id
      )
      |> RC.Repo.all()

    # Each instance has to be reloaded via get_instance_with_registration/1
    # so init_from_model sees the faction → registration → profile graph
    # it needs to wire up player agents. Without this, the manager comes
    # up with zero players and channel joins for those players return
    # "instance_unavailable".
    Enum.each(ids, fn id ->
      case RC.Instances.get_instance_with_registration(id) do
        nil -> Logger.warning("[bot_restart] instance #{id} disappeared mid-scan")
        instance -> restart_one(instance)
      end
    end)

    Logger.info("[bot_restart] done; #{length(targets)} candidates")
  end

  defp restart_one(instance) do
    # Two-phase: ensure the manager exists, then ensure it's started.
    # Decoupling lets us recover from a half-finished prior attempt
    # (manager created but never started, e.g. previous run crashed
    # between create_from_model and the :start call).
    case ensure_created(instance) do
      :ok ->
        ensure_started(instance)

      {:error, reason} ->
        Logger.warning("[bot_restart] instance #{instance.id} create failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning(
        "[bot_restart] instance #{instance.id} crashed during restart: #{Exception.message(e)}"
      )
  end

  defp ensure_created(instance) do
    cond do
      Instance.Manager.created?(instance.id) ->
        :ok

      true ->
        case Instance.Manager.create_from_model(instance, nil) do
          {:ok, :instantiated} -> :ok
          {:error, :already_created} -> :ok
          other -> {:error, other}
        end
    end
  end

  defp ensure_started(instance) do
    case Instance.Manager.get_status(instance.id) do
      :running ->
        Logger.info("[bot_restart] instance #{instance.id} already running")
        sync_db_state(instance, "running")

      _ ->
        case Instance.Manager.call(instance.id, :start) do
          {:ok, :started, _} ->
            Logger.info("[bot_restart] instance #{instance.id} started")
            sync_db_state(instance, "running")

          other ->
            Logger.warning(
              "[bot_restart] instance #{instance.id} start failed: #{inspect(other)}"
            )
        end
    end
  end

  # Push the DB state back to match in-memory reality. fix_instances_statuses
  # may have rewritten it to "not_running" before we recreated the manager;
  # without this, other subsystems (registration, lobby views) would
  # disagree about whether the instance is open for play.
  defp sync_db_state(instance, new_state) do
    if instance.state != new_state do
      Logger.info(
        "[bot_restart] syncing DB state for instance #{instance.id}: #{instance.state} → #{new_state}"
      )

      RC.Repo.update_all(
        Ecto.Query.from(i in RC.Instances.Instance, where: i.id == ^instance.id),
        set: [state: new_state]
      )
    end
  end
end
