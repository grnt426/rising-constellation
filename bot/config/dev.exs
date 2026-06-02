import Config

config :rc_bot,
  # Server under test. Override via RC_BOT_TARGET env var at runtime.
  target_http: "http://localhost:4000",
  target_ws: "ws://localhost:4000/socket/websocket",
  # Don't auto-start the fleet in dev — let the operator drive it from
  # iex (RcBot.Fleet.start_bot(...)) so failures surface in the shell.
  autostart_fleet: false
