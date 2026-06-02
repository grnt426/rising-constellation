import Config

config :rc_bot,
  # Server under test. Override via RC_BOT_TARGET env var at runtime.
  target_http: "http://localhost:4000",
  target_ws: "ws://localhost:4000/socket/websocket",
  # Don't auto-start the fleet in dev — let the operator drive it from
  # iex (RcBot.Fleet.start_bot(...)) so failures surface in the shell.
  autostart_fleet: false,
  # Schedule defaults. Tight idle for dev so you see the bots cycle
  # within a few minutes; production runs override via runtime.exs.
  schedule: %{
    launch_surge_seconds: 10,
    idle_seconds_min: 30,
    idle_seconds_max: 120,
    peak_hours: [],
    peak_factor: 0.3,
    jitter_seconds: 5
  },
  # Per-session defaults merged into each bot's spawn args by the
  # orchestrator. Override per-bot in the roster entry if needed.
  session_defaults: %{
    bursts_total: 5,
    inter_burst_ms_min: 3_000,
    inter_burst_ms_max: 15_000
  },
  # Roster — empty in source. Override in a gitignored bot/config/local.exs
  # or via runtime.exs for production.
  roster: []
