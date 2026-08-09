defmodule Game.News do
  @moduledoc """
  Public API for the news-ticker system.

  Call `Game.News.emit/3` from anywhere a newsworthy event happens
  (battles, colonizations, building completions, patent unlocks,
  agent ops, etc.). The call is fire-and-forget — it publishes to a
  per-instance Phoenix.PubSub topic and the per-instance
  `Game.News.Server` decides whether the event is actually news
  (firsts gate, dedup window, fast/tutorial speed gate, etc.) and
  persists it.

  ## Lazy server start

  The News.Server for an instance is lazy-started on the first emit
  rather than wired into the supervision-tree boot path. This keeps
  the seed PR small (no surgery in `Instance.Manager` /
  `Instance.Supervisor`) and the first emit pays a tiny one-time cost
  to bring the server up. Subsequent emits go straight through the
  cached PubSub topic.

  ## Speed/tutorial gate

  News.Server short-circuits if the instance speed is `:fast` or the
  galaxy is a tutorial. The check is cached in server state so we
  only pay the lookup once per server lifetime.
  """

  require Logger

  @doc """
  Emit a news event for the given instance.

  `key` is a dotted string like `"colonize.first"` — the
  `News.Server` uses it to dispatch to a rule (claim_first, dedup,
  etc.). `payload` is an arbitrary map; the renderer on the frontend
  picks fields out of it by template-variant key.

  Returns `:ok` unconditionally. Returns immediately if the instance
  isn't running (no News.Server can be started).
  """
  def emit(instance_id, key, payload) when is_integer(instance_id) and is_binary(key) and is_map(payload) do
    case ensure_server(instance_id) do
      :ok ->
        Phoenix.PubSub.broadcast(RC.PubSub, topic(instance_id), {:news_emit, key, payload})
        :ok

      :no_instance ->
        :ok
    end
  end

  @doc "PubSub topic for a given instance's news stream."
  def topic(instance_id), do: "news:#{instance_id}"

  # Bring up the per-instance News.Server on first emit. Idempotent —
  # subsequent calls just verify it's still registered.
  defp ensure_server(instance_id) do
    case Game.get_pid({instance_id, :news_server}, 1) do
      {:ok, _pid} ->
        :ok

      _ ->
        case Instance.Supervisor.get_pid(instance_id) do
          {:ok, supervisor_pid} ->
            spec = {Game.News.Server, instance_id: instance_id}

            case DynamicSupervisor.start_child(supervisor_pid, spec) do
              {:ok, _pid} ->
                :ok

              {:error, {:already_started, _pid}} ->
                :ok

              {:error, reason} ->
                Logger.warning("Game.News.ensure_server failed to start News.Server",
                  instance_id: instance_id,
                  reason: inspect(reason)
                )

                :no_instance
            end

          _ ->
            :no_instance
        end
    end
  end
end
