# Live smoke test: start the orchestrator with the prod-backed roster
# and let it run for ~90 seconds. The Orchestrator pulls assignments
# from /api/harness/bot-assignments and spawns sessions as scheduled.
#
# Expected: at least one bot reaches the burst stage, server-side
# bot_events rows accumulate, dashboard shows activity.

require Logger

# Tight schedule for a smoke test — first session within seconds,
# short idle, short bursts so we see end-to-end activity in <90s.
Application.put_env(:rc_bot, :schedule, %{
  launch_surge_seconds: 5,
  idle_seconds_min: 10,
  idle_seconds_max: 20,
  peak_hours: [],
  peak_factor: 1.0,
  jitter_seconds: 3
})

Application.put_env(:rc_bot, :session_defaults, %{
  bursts_total: 2,
  inter_burst_ms_min: 2_000,
  inter_burst_ms_max: 5_000
})

Logger.info("Starting Orchestrator against #{Application.fetch_env!(:rc_bot, :target_http)}")
{:ok, _pid} = RcBot.Orchestrator.start_link([])

# Let it run, print status periodically.
for i <- 1..18 do
  Process.sleep(5_000)
  status = RcBot.Orchestrator.status()
  running = Enum.filter(status.bots, & &1.running) |> length()

  Logger.info(
    "t=#{i * 5}s — #{length(status.bots)} bots, #{running} running, fleet_enabled=true"
  )
end

Logger.info("Done.")
