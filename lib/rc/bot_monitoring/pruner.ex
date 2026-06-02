defmodule RC.BotMonitoring.Pruner do
  @moduledoc """
  Periodic deletion of old `bot_events` rows so the table doesn't grow
  unbounded across weeks of legacy stress runs. Runs on its own tick;
  failures are logged but don't crash the supervisor.

  Default: delete rows older than 30 days, every 24 hours.
  """

  use GenServer

  require Logger

  alias RC.BotMonitoring

  @default_interval_ms 24 * 60 * 60 * 1000
  @default_retention_days 30
  # Wait this long after start before the first prune so we don't compete
  # with boot-time DB activity.
  @initial_delay_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    retention = Keyword.get(opts, :retention_days, @default_retention_days)

    schedule(@initial_delay_ms)
    {:ok, %{interval_ms: interval, retention_days: retention}}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      deleted = BotMonitoring.prune_older_than(state.retention_days)
      if deleted > 0, do: Logger.info("bot_events: pruned #{deleted} rows older than #{state.retention_days}d")
    rescue
      e -> Logger.warning("bot_events prune failed: #{Exception.message(e)}")
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp schedule(ms), do: Process.send_after(self(), :prune, ms)
end
