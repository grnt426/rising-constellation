defmodule Portal.Endpoint do
  require EnvOnly

  use Phoenix.Endpoint, otp_app: :rc

  # Session cookie config. `secure` is omitted here because plug options are
  # baked at compile time and we want the secure flag to track the runtime
  # RC_FORCE_SSL setting (so the same release can run with TLS or without).
  # See `Portal.Plug.MaybeSession` for the runtime decision.
  @session_options [
    store: :cookie,
    key: "_portal_key",
    signing_salt: "rWCMKEW0",
    http_only: true,
    same_site: "Lax"
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
  #
  # MaybeSSL wraps Plug.SSL so the behavior can be turned off at runtime
  # via RC_FORCE_SSL=false — needed for HTTP-only test deploys, off by
  # default in real prod.
  EnvOnly.prod do
    plug(Portal.Plug.MaybeSSL)
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

  # Stage 5 #B1.5 fix.
  #
  # Was 100 MB. The only routes that legitimately accept bodies anywhere
  # near that size are the upload endpoints (capped at `max_image_size:
  # 50_000_000` in config). Setting Plug.Parsers length to match the
  # upload ceiling halves the worst-case body-bomb size for every other
  # route. Anything larger is rejected at the parser layer with a
  # `Plug.Parsers.RequestTooLargeError`.
  #
  # Plug.Parsers can only run once (the body is consumed), so we can't
  # have a smaller cap on /api/health and a larger cap on /api/uploads
  # without a custom body_reader — that's a structural refactor deferred
  # for a follow-up.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 50_000_000
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  # CORS allowlist resolves to :rc, :rc_domain at request time — see
  # Portal.Plug.MaybeCorsica. Plug options bake at compile time, so the
  # bare `plug Corsica, origins: ...` form would freeze the value at
  # build time. (Also: `:self` is only valid inside Corsica.Router, not
  # as a plain plug option — passing it raises FunctionClauseError once
  # an actual Origin header arrives. Don't try it again.)
  plug(Portal.Plug.MaybeCorsica)

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  plug(Portal.Plug.MaybeSession, opts: @session_options)

  plug(Portal.Router)

end
