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

    targets =
      from(i in RC.Instances.Instance,
        where: i.is_bot_only == true,
        # Only attempt for instances that were running/paused last we knew.
        # "open"/"created"/"ended"/"not_running" are intentional dormant
        # states — leave them alone.
        where: i.state in ["running", "paused"],
        select: i
      )
      |> RC.Repo.all()

    Enum.each(targets, &restart_one/1)

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

      _ ->
        case Instance.Manager.call(instance.id, :start) do
          {:ok, :started, _} ->
            Logger.info("[bot_restart] instance #{instance.id} started")

          other ->
            Logger.warning(
              "[bot_restart] instance #{instance.id} start failed: #{inspect(other)}"
            )
        end
    end
  end
end
