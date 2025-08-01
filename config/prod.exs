import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.
#
# Note we also include the path to a cache manifest
# containing the digested version of static files. This
# manifest is generated by the `mix phx.digest` task,
# which you should run after static files are built and
# before starting your production server.
config :rc, Portal.Endpoint,
  http: [:inet6, port: 4000, protocol_options: [idle_timeout: 1_000_000]],
  url: [host: "a-new-rising.space", port: 443],
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: false,
  server: true

# Default rc mode
config :rc,
  ecto_repos: [RC.Repo],
  rc_domain: "https://a-new-rising.space/",
  environment: :prod,
  signup_mode: :mail_validation,
  login_mode: :enabled,
  revision: File.read!("priv/VERSION") |> String.trim()

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

config :logger, :gelf_logger,
  host: "log.malt.li",
  port: 12_201,
  format: "$message",
  application: "rc",
  metadata: ~w(
    request_id pid mfa function module file line registered_name
    crash_reason instance_id type agent_id action
  )a,
  json_encoder: Jason,
  tags: [
    env: "prod"
  ]

# ## SSL Support
#
# To get SSL working, you will need to add the `https` key
# to the previous section and set your `:url` port to 443:
#
#     config :rc, Portal.Endpoint,
#       ...
#       url: [host: "example.com", port: 443],
#       https: [
#         :inet6,
#         port: 443,
#         cipher_suite: :strong,
#         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
#         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
#       ]
#
# The `cipher_suite` is set to `:strong` to support only the
# latest and more secure SSL ciphers. This means old browsers
# and clients may not be supported. You can set it to
# `:compatible` for wider support.
#
# `:keyfile` and `:certfile` expect an absolute path to the key
# and cert in disk or a relative path inside priv, for example
# "priv/ssl/server.key". For all supported SSL configuration
# options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
#
# We also recommend setting `force_ssl` in your endpoint, ensuring
# no data is ever sent via http, always redirecting to https:
#
#     config :rc, Portal.Endpoint,
#       force_ssl: [hsts: true]
#
# Check `Plug.SSL` for all available options in `force_ssl`.

# ## Using releases (distillery)
#
# If you are doing OTP releases, you need to instruct Phoenix
# to start the server for all endpoints:
#
config :phoenix, :serve_endpoints, true
#
# Alternatively, you can configure exactly which server to
# start per endpoint:
#
#     config :rc, Portal.Endpoint, server: true
#
# Note you can't rely on `System.get_env/1` when using releases.
# See the releases documentation accordingly.

# Enable Appsignal
config :appsignal, :config, active: true, revision: File.read!("priv/VERSION") |> String.trim()

config :waffle,
  storage: Waffle.Storage.S3,
  bucket: "waffle-uploads",
  storage_dir: "/storage",
  asset_host: "https://waffle-uploads.s3.fr-par.scw.cloud/"

config :libcluster,
  topologies: [
    rc_servers: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "nodes.rising-constellation.com",
        node_basename: "rc"]]]

# Finally import the config/prod.secret.exs which should be versioned
# separately.
import_config "prod.secret.exs"
