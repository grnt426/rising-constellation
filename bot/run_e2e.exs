# One-shot end-to-end test: start a single bot session and wait for it to
# finish all its bursts. Used by docker-compose to verify the harness
# against a live rc server.
#
# Exit codes:
#   0 — bot session completed cleanly
#   1 — bot session crashed or timed out

require Logger

bot_args =
  [
    bot_id: "e2e-1",
    email: System.fetch_env!("BOT_EMAIL"),
    password: System.fetch_env!("BOT_PASSWORD"),
    profile_id: String.to_integer(System.fetch_env!("BOT_PROFILE_ID")),
    instance_id: String.to_integer(System.fetch_env!("BOT_INSTANCE_ID")),
    faction_id: String.to_integer(System.fetch_env!("BOT_FACTION_ID")),
    bursts_total: String.to_integer(System.get_env("BOT_BURSTS", "2")),
    inter_burst_ms_min: String.to_integer(System.get_env("BOT_INTER_BURST_MIN_MS", "2000")),
    inter_burst_ms_max: String.to_integer(System.get_env("BOT_INTER_BURST_MAX_MS", "4000"))
  ]
  |> then(fn args ->
    case System.get_env("BOT_REGISTRATION_TOKEN") do
      nil -> args
      token -> Keyword.put(args, :registration_token, token)
    end
  end)

{:ok, pid} = RcBot.Fleet.start_bot(bot_args)
ref = Process.monitor(pid)

# Estimate timeout: bursts_total bursts × (~1.5s settle + inter_burst_max) +
# 15s slack for connect.
timeout =
  15_000 +
    bot_args[:bursts_total] *
      (bot_args[:inter_burst_ms_max] + 2_000)

receive do
  {:DOWN, ^ref, :process, ^pid, :normal} ->
    Logger.info("E2E PASS — bot exited normally")
    System.halt(0)

  {:DOWN, ^ref, :process, ^pid, reason} ->
    Logger.error("E2E FAIL — bot crashed: #{inspect(reason)}")
    System.halt(1)
after
  timeout ->
    Logger.error("E2E FAIL — timeout (#{timeout}ms) waiting for bot to finish")
    System.halt(1)
end
