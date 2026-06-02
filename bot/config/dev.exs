import Config

config :rc_bot,
  # Server under test. Override via RC_BOT_TARGET env var at runtime.
  target_http: "http://localhost:4000",
  target_ws: "ws://localhost:4000/socket/websocket",
  # Don't auto-start the fleet in dev — let the operator drive it from
  # iex (RcBot.Fleet.start_bot(...)) so failures surface in the shell.
  autostart_fleet: false,
  # Schedule defaults — sized for "realistic legacy player" cadence.
  # A real player logs in every few hours, plays for ~5–20 min, logs
  # off. Aggregated across 30 bots that's ~15 sessions/hr fleet-wide,
  # each ~10 min long — i.e. each bot is "online" ~10% of the time.
  #
  # For tight smoke testing override via the run_*.exs scripts (they
  # already do — see run_prod_smoke.exs / run_pause_e2e.exs).
  schedule: %{
    launch_surge_seconds: 60,
    # 30 min – 4 hr between sessions; peak hours cut that to ~12 min – 1.6 hr.
    idle_seconds_min: 30 * 60,
    idle_seconds_max: 4 * 60 * 60,
    peak_hours: [],
    peak_factor: 0.4,
    # Per-bot wake jitter (5 min) so 30 bots don't wake on the same tick.
    jitter_seconds: 5 * 60
  },
  # Per-session defaults merged into each bot's spawn args by the
  # orchestrator. Override per-bot in the roster entry if needed.
  # ~8 bursts × ~90s avg = ~12 min session.
  session_defaults: %{
    bursts_total: 8,
    inter_burst_ms_min: 30_000,
    inter_burst_ms_max: 180_000
  },
  # Roster — empty in source. Override in a gitignored bot/config/local.exs
  # or via runtime.exs for production.
  roster: []
