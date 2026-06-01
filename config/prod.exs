import Config

# Compile-time prod config only. Anything that varies per environment
# (hostnames, secrets, credentials, cluster topology, log endpoints) lives in
# `config/runtime.exs` and is read from env vars at release boot.

config :rc,
  ecto_repos: [RC.Repo],
  environment: :prod,
  revision: File.read!("priv/VERSION") |> String.trim()

config :rc, Portal.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# `check_origin` defaults to the configured `:url` host (set in
# config/runtime.exs from $RC_HOST) which is the right behavior. The
# previous `check_origin: false` here let any third-party origin open a
# WebSocket if it knew a JWT.

config :logger,
  backends: [{Logger.Backends.Gelf, :gelf_logger}],
  utc_log: true,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :plug_logger_json,
  filtered_keys: ["password", "authorization"],
  suppressed_keys: ["api_version", "log_type", "client_version"]

# Static parts of the GELF formatter. Host/port/tags come from runtime.exs.
config :logger, :gelf_logger,
  format: "$message",
  application: "rc",
  metadata: ~w(
    request_id pid mfa function module file line registered_name
    crash_reason instance_id type agent_id action
  )a,
  json_encoder: Jason

# Release-mode Phoenix needs this to actually start endpoints.
config :phoenix, :serve_endpoints, true

# AppSignal is enabled per-deploy via APPSIGNAL_ACTIVE in runtime.exs.
config :appsignal, :config, revision: File.read!("priv/VERSION") |> String.trim()
