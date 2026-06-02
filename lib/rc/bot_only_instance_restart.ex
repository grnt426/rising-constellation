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
    cond do
      Instance.Manager.created?(instance.id) ->
        Logger.info("[bot_restart] instance #{instance.id} already created — skipping")

      true ->
        case Instance.Manager.create_from_model(instance, nil) do
          {:ok, :instantiated} ->
            case Instance.Manager.call(instance.id, :start) do
              {:ok, :started, _} ->
                # Also reset the DB-side state machine via the existing path,
                # so the registration_status etc. are consistent.
                case RC.Instances.start_instance(instance, instance.account_id) do
                  {:ok, _} ->
                    Logger.info("[bot_restart] instance #{instance.id} re-instantiated + started")

                  other ->
                    Logger.warning(
                      "[bot_restart] instance #{instance.id} started in memory but state reset failed: #{inspect(other)}"
                    )
                end

              other ->
                Logger.warning(
                  "[bot_restart] instance #{instance.id} manager start failed: #{inspect(other)}"
                )
            end

          other ->
            Logger.warning(
              "[bot_restart] instance #{instance.id} create_from_model failed: #{inspect(other)}"
            )
        end
    end
  rescue
    e ->
      Logger.warning("[bot_restart] instance #{instance.id} crashed during restart: #{Exception.message(e)}")
  end
end
