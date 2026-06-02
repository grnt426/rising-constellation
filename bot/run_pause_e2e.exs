require Logger

target_http = Application.fetch_env!(:rc_bot, :target_http)
secret = System.fetch_env!("RC_BOT_HARNESS_SECRET")

flip = fn enabled ->
  # Use admin endpoint via JWT
  {:ok, %{status: 200, body: %{"token" => jwt}}} =
    Req.post(target_http <> "/api/auth/identity/callback",
      json: %{account: %{email: "admin@abc", password: "admindev"}},
      retry: false
    )

  {:ok, resp} =
    Req.put(target_http <> "/api/admin/bot-control/state",
      json: %{enabled: enabled},
      auth: {:bearer, jwt},
      retry: false
    )

  Logger.info("flipped fleet to #{enabled}: #{inspect(resp.body)}")
end

# Start with fleet enabled (current state)
flip.(true)

# Start orchestrator with a tight schedule
Application.put_env(:rc_bot, :schedule, %{
  launch_surge_seconds: 2,
  idle_seconds_min: 2,
  idle_seconds_max: 4,
  peak_hours: [],
  peak_factor: 1.0,
  jitter_seconds: 1
})

Application.put_env(:rc_bot, :session_defaults, %{
  bursts_total: 1,
  inter_burst_ms_min: 500,
  inter_burst_ms_max: 1_000
})

{:ok, _pid} = RcBot.Orchestrator.start_link([])

Process.sleep(8_000)
status = RcBot.Orchestrator.status()
Logger.info("after 8s with fleet=true: #{inspect(status.bots |> Enum.map(&Map.take(&1, [:bot_id, :running])))}")

# Now PAUSE the fleet
flip.(false)

# Wait for the orchestrator's cache to expire (10s TTL) and pick up the
# new state, then wait for any in-flight session to finish + new wake
# to defer.
Logger.info("waiting for cache expiry + a wake cycle…")
Process.sleep(25_000)

status = RcBot.Orchestrator.status()
running = status.bots |> Enum.filter(& &1.running) |> length()

if running == 0 do
  Logger.info("E2E PASS — orchestrator stopped spawning new sessions after pause")
  flip.(true)
  System.halt(0)
else
  Logger.error("E2E FAIL — #{running} bot still running #{inspect(status.bots)}")
  flip.(true)
  System.halt(1)
end
