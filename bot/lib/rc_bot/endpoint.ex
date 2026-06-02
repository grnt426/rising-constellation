defmodule RcBot.Endpoint do
  @moduledoc """
  Driver-side admin endpoint. Serves the `/bots` LiveView at
  `http://localhost:5500/` so a developer running this harness on their
  laptop can observe and control the local orchestrator.

  Binds to 127.0.0.1 only — single-operator tool, no auth. If you ever
  want to deploy a harness somewhere shared, put it behind nginx +
  basic auth or add real authn here first.
  """

  use Phoenix.Endpoint, otp_app: :rc_bot

  socket("/live", Phoenix.LiveView.Socket, websocket: true, longpoll: false)

  # Phoenix + LV client JS pulled directly from the deps' priv dirs.
  # Keeps the harness asset-pipeline-free.
  plug(Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/assets/live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:rc_bot, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(RcBot.Router)
end
