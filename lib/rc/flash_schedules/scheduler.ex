defmodule RC.FlashSchedules.Scheduler do
  @moduledoc """
  Minute tick for scheduled Flash matches (see RC.FlashSchedules):
  create due lobbies, keep their Discord guild scheduled events in sync,
  announce them in #lfg, close lobbies unstarted after 48h, and post
  results of finished matches. Every step is idempotent and isolated, so
  a failure in one never blocks the others or the next tick.

  Events are synced before the announcement so a lobby created this tick
  can already link its event in #lfg.

  Not started in the test environment — tests call the steps directly.
  """

  use GenServer

  require Logger

  alias RC.Discord.{FlashAnnouncer, FlashEvent}
  alias RC.FlashSchedules

  @interval :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    # First tick after the boot-restore rush.
    Process.send_after(self(), :tick, :timer.seconds(30))
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  @doc "One pass of every step (also handy from `rc rpc`)."
  def tick(now \\ DateTime.utc_now()) do
    step(:create, fn -> FlashSchedules.create_due_matches(now) end)
    step(:expire, fn -> FlashSchedules.expire_stale_matches(now) end)
    step(:events, fn -> sync_events(now) end)
    step(:announce, &announce_pending/0)
    step(:results, &post_results/0)
    :ok
  end

  defp announce_pending do
    for match <- FlashSchedules.unannounced_matches() do
      match
      |> FlashSchedules.announcement_data()
      |> FlashAnnouncer.announcement_embed()
      |> FlashAnnouncer.post()
      |> mark(match, :announced_at)
    end
  end

  defp post_results do
    for match <- FlashSchedules.unposted_results() do
      match
      |> FlashSchedules.result_data()
      |> FlashAnnouncer.result_embed()
      |> FlashAnnouncer.post()
      |> mark(match, :result_posted_at)
    end
  end

  # Discord guild scheduled events: one per occurrence, created with the
  # lobby and re-pushed whenever its player counts or its status change.
  defp sync_events(now) do
    for match <- FlashSchedules.matches_needing_event_sync(now) do
      data = FlashSchedules.event_data(match, now)

      case FlashEvent.plan(match, data) do
        :none -> :none
        {:create, params, record} -> create_event(match, params, record)
        {:modify, params, record} -> modify_event(match, params, record)
      end
    end
  end

  defp create_event(match, params, record) do
    case FlashEvent.create(params) do
      {:ok, event_id} ->
        FlashSchedules.record_event(match, Map.put(record, :discord_event_id, event_id))

      # Discord refused the event (most likely the bot is missing Manage
      # Events). Latch it so the next 48h of ticks don't retry every
      # minute; clearing the column retries.
      {:error, _reason} ->
        FlashSchedules.record_event(match, %{discord_event_status: "failed"})

      :skipped ->
        :skipped
    end
  end

  # A push that Discord saw — accepted or refused — is done, the same rule
  # the #lfg posts follow: only a bot that isn't running retries. A refused
  # patch is re-attempted as soon as the counts move again.
  defp modify_event(match, params, record) do
    case FlashEvent.modify(match.discord_event_id, params) do
      :skipped -> :skipped
      _result -> FlashSchedules.record_event(match, record)
    end
  end

  # A post that was attempted (sent or refused by Discord) is done; only a
  # bot that isn't running leaves it pending for a later tick.
  defp mark(:skipped, _match, _field), do: :skipped
  defp mark(_result, match, field), do: FlashSchedules.mark(match, field)

  defp step(name, fun) do
    fun.()
  rescue
    e -> Logger.error("[flash_scheduler] #{name} failed: #{Exception.format(:error, e, __STACKTRACE__)}")
  end
end
