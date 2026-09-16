defmodule RC.FlashSchedules.Scheduler do
  @moduledoc """
  Minute tick for scheduled Flash matches (see RC.FlashSchedules):
  create due lobbies, announce them in #lfg, close lobbies unstarted after
  48h, and post results of finished matches. Every step is idempotent and
  isolated, so a failure in one never blocks the others or the next tick.

  Not started in the test environment — tests call the steps directly.
  """

  use GenServer

  require Logger

  alias RC.Discord.FlashAnnouncer
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
