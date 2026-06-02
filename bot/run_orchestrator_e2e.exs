# Orchestrator end-to-end test: configure a 1-bot roster with tight
# timings, let the orchestrator drive at least one full session cycle
# (login → bursts → logout → idle → next session), then exit.
#
# Exit codes:
#   0 — saw the bot complete a session and the orchestrator scheduled the next
#   1 — timeout / failure

require Logger

# Configure the roster from env vars.
roster_entry = %{
  bot_id: System.get_env("BOT_ID", "orch-1"),
  email: System.fetch_env!("BOT_EMAIL"),
  password: System.fetch_env!("BOT_PASSWORD"),
  profile_id: String.to_integer(System.fetch_env!("BOT_PROFILE_ID")),
  instance_id: String.to_integer(System.fetch_env!("BOT_INSTANCE_ID")),
  faction_id: String.to_integer(System.fetch_env!("BOT_FACTION_ID"))
}

# Tight schedule so the test completes in under a minute.
Application.put_env(:rc_bot, :roster, [roster_entry])

Application.put_env(:rc_bot, :schedule, %{
  launch_surge_seconds: 2,
  idle_seconds_min: 3,
  idle_seconds_max: 5,
  peak_hours: [],
  peak_factor: 1.0,
  jitter_seconds: 1
})

Application.put_env(:rc_bot, :session_defaults, %{
  bursts_total: 2,
  inter_burst_ms_min: 1_000,
  inter_burst_ms_max: 2_000
})

{:ok, _pid} = RcBot.Orchestrator.start_link([])

# Poll the orchestrator status until we observe the bot moving through
# a full cycle: running → not running → running again.
target_bot = roster_entry.bot_id

wait_for = fn predicate, timeout_ms ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms

  Stream.repeatedly(fn ->
    status = RcBot.Orchestrator.status()
    Process.sleep(500)
    status
  end)
  |> Enum.reduce_while(nil, fn status, _ ->
    bot = Enum.find(status.bots, &(&1.bot_id == target_bot))

    cond do
      predicate.(bot) -> {:halt, :ok}
      System.monotonic_time(:millisecond) > deadline -> {:halt, :timeout}
      true -> {:cont, status}
    end
  end)
end

Logger.info("Waiting for bot to start its first session…")
:ok = wait_for.(fn b -> b && b.running end, 30_000)
Logger.info("First session started.")

Logger.info("Waiting for bot to finish its session (running → not running)…")

case wait_for.(fn b -> b && not b.running end, 60_000) do
  :ok ->
    Logger.info("Session ended. Waiting for next session to start…")

    case wait_for.(fn b -> b && b.running end, 30_000) do
      :ok ->
        Logger.info("E2E PASS — orchestrator drove a full session + scheduled the next")
        System.halt(0)

      :timeout ->
        Logger.error("E2E FAIL — orchestrator never scheduled the next session")
        System.halt(1)
    end

  :timeout ->
    Logger.error("E2E FAIL — bot session never ended")
    System.halt(1)
end
