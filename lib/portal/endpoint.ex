defmodule Portal.Endpoint do
  require EnvOnly

  use Phoenix.Endpoint, otp_app: :rc

  @session_options [
    store: :cookie,
    key: "_portal_key",
    signing_salt: "rWCMKEW0",
    http_only: true,
    same_site: "Lax",
    # `Secure` is required in prod (we run behind a TLS-terminating proxy)
    # but would break dev where Phoenix listens on plain HTTP for localhost.
    # Mix.env() resolves at compile time.
    secure: Mix.env() == :prod
  ]

  # `max_frame_size` caps incoming WebSocket frames at 64 KB. Stage 4 #H7
  # noted that without a cap an authenticated player could spam handle_in
  # events with multi-MB padded payloads, each persisted verbatim into
  # the replays table (no length validation in the changeset or migration).
  # 64 KB is generous for legitimate game actions while making
  # disk-fill-by-replay-spam impractical.
  socket("/socket", Portal.Socket,
    websocket: [max_frame_size: 64_000],
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug(Plug.Static,
    at: "/",
    from: :rc,
    gzip: true
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  #
  # Phoenix.CodeReloader runs `mix compile` on every request to check for
  # stale modules. Over the Docker bind mount on Windows, that stat-walk
  # adds ~3s of latency to every request (including ones that don't touch
  # any Elixir code — static assets, proxied Vue chunks, and even 404s).
  # We skip it here for dev iteration speed. Phoenix.LiveReloader is kept:
  # it only injects the live-reload JS snippet and watches static assets,
  # which is microseconds-fast.
  #
  # The tradeoff: Elixir source edits no longer take effect on the next
  # request. To pick them up, either:
  #   - `docker compose restart rc`, or
  #   - run with `iex -S mix phx.server` and use `recompile` in IEx, or
  #   - call `Phoenix.CodeReloader.reload!(Portal.Endpoint)` in IEx.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :portal)
  end

  # In prod: redirect plain-HTTP requests to HTTPS at the app layer and
  # emit HSTS so browsers won't speak HTTP to us again. `rewrite_on:
  # [:x_forwarded_proto]` is required because TLS terminates at the proxy
  # — without it Plug.SSL only sees `http://` and 301s every request.
  EnvOnly.prod do
    plug(Plug.SSL,
      rewrite_on: [:x_forwarded_proto],
      hsts: true,
      expires: 31_536_000,
      subdomains: true
    )
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  EnvOnly.not_prod do
    plug(Plug.Logger)
  end

  EnvOnly.prod do
    plug(Plug.LoggerJSON, log: Logger.level())
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 100_000_000
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Corsica,
    allow_credentials: true,
    allow_headers: :all,
    origins: &Portal.Endpoint.cors_origin?/2
  )

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  plug(Plug.Session, @session_options)

  plug(Portal.Router)

  # Matches CORS Origin headers against :rc_domain at runtime, so the value
  # set via env var in runtime.exs is honored without a rebuild. Trailing
  # slashes are normalized — :rc_domain is canonically stored as
  # "https://host/" but browsers send Origin without the trailing slash.
  @doc false
  def cors_origin?(origin, _conn) do
    case Application.get_env(:rc, :rc_domain) do
      nil ->
        false

      allowed when is_binary(allowed) ->
        normalized = String.trim_trailing(allowed, "/")
        origin == allowed or origin == normalized
    end
  end
end
