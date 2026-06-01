import Config

# Runtime configuration. Evaluated when the release boots (and on
# `mix phx.server` for non-prod envs that opt in below). Reads env vars so a
# single release artifact can run under any domain / credentials.
#
# See DEPLOYMENT.md and .env.example for the env-var contract.

if config_env() == :prod do
  # --- Helpers ----------------------------------------------------------------
  get_env_required = fn name ->
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise """
        environment variable #{name} is missing.
        See .env.example for the full list of required variables.
        """
    end
  end

  get_env_int = fn name, default ->
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  get_env_bool = fn name, default ->
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value in ~w(1 true yes on)
    end
  end

  # --- Phoenix endpoint -------------------------------------------------------
  host = get_env_required.("RC_HOST")
  url_port = get_env_int.("RC_URL_PORT", 443)
  http_port = get_env_int.("RC_HTTP_PORT", 4000)
  scheme = System.get_env("RC_SCHEME") || "https"
  rc_domain = System.get_env("RC_DOMAIN") || "#{scheme}://#{host}/"

  config :rc, Portal.Endpoint,
    http: [:inet6, port: http_port, protocol_options: [idle_timeout: 1_000_000]],
    url: [host: host, port: url_port, scheme: scheme],
    secret_key_base: get_env_required.("SECRET_KEY_BASE"),
    server: true

  # --- App-wide -------------------------------------------------------------
  config :rc,
    rc_domain: rc_domain,
    support_email: System.get_env("RC_SUPPORT_EMAIL") || "support@#{host}",
    signup_mode: String.to_atom(System.get_env("RC_SIGNUP_MODE") || "mail_validation"),
    login_mode: String.to_atom(System.get_env("RC_LOGIN_MODE") || "enabled"),
    force_ssl: get_env_bool.("RC_FORCE_SSL", true)

  # --- Database -------------------------------------------------------------
  database_url = get_env_required.("DATABASE_URL")
  pool_size = get_env_int.("POOL_SIZE", 10)

  config :rc, RC.Repo,
    url: database_url,
    pool_size: pool_size,
    ssl: get_env_bool.("DATABASE_SSL", false)

  # --- Guardian (JWT signing) -----------------------------------------------
  config :rc, RC.Guardian,
    issuer: "rc",
    secret_key: get_env_required.("GUARDIAN_SECRET_KEY")

  # --- Mailer ---------------------------------------------------------------
  config :rc, RC.Mailer,
    adapter: Swoosh.Adapters.Mailjet,
    api_key: get_env_required.("MAILER_API_KEY"),
    secret: get_env_required.("MAILER_SECRET"),
    sender:
      {System.get_env("MAILER_SENDER_NAME") || "Rising Constellation",
       System.get_env("MAILER_SENDER_EMAIL") || "support@#{host}"},
    verification_template: get_env_int.("MAILER_VERIFICATION_TEMPLATE", 1_352_021),
    password_reset_template: get_env_int.("MAILER_PASSWORD_RESET_TEMPLATE", 1_363_520),
    email_update_template: get_env_int.("MAILER_EMAIL_UPDATE_TEMPLATE", 1_699_096),
    web_bind_template: get_env_int.("MAILER_WEB_BIND_TEMPLATE", 3_028_081)

  # --- Object storage (Waffle + ex_aws) -------------------------------------
  config :waffle,
    storage: Waffle.Storage.S3,
    bucket: get_env_required.("S3_BUCKET"),
    storage_dir: System.get_env("S3_STORAGE_DIR") || "/storage",
    asset_host: get_env_required.("S3_ASSET_HOST")

  config :ex_aws, :s3,
    access_key_id: get_env_required.("AWS_ACCESS_KEY_ID"),
    secret_access_key: get_env_required.("AWS_SECRET_ACCESS_KEY"),
    region: System.get_env("AWS_REGION") || "us-east-1",
    scheme: System.get_env("S3_SCHEME") || "https://",
    host: System.get_env("S3_HOST") || "s3.amazonaws.com"

  # --- Stripe (optional; only required if billing is enabled) ---------------
  if System.get_env("STRIPE_API_KEY") do
    config :stripity_stripe,
      api_key: System.get_env("STRIPE_API_KEY"),
      public_key: System.get_env("STRIPE_PUBLIC_KEY")
  end

  # --- Steam (optional) -----------------------------------------------------
  if System.get_env("STEAMWORKS_WEB_API_SECRET") do
    config :rc, steamworks_web_api_secret: System.get_env("STEAMWORKS_WEB_API_SECRET")
  end

  # --- AppSignal ------------------------------------------------------------
  # `revision` is set at build time in config/prod.exs (where the CWD has
  # access to priv/VERSION). Only the per-deploy toggles live here.
  appsignal_active = get_env_bool.("APPSIGNAL_ACTIVE", false)

  config :appsignal, :config,
    active: appsignal_active,
    push_api_key: System.get_env("APPSIGNAL_PUSH_API_KEY") || ""

  # --- GELF logger (optional; falls back to console if no host) -------------
  case System.get_env("GELF_HOST") do
    host when is_binary(host) and host != "" ->
      config :logger, :gelf_logger,
        host: host,
        port: get_env_int.("GELF_PORT", 12_201),
        tags: [env: System.get_env("RC_ENV_TAG") || "prod"]

    _ ->
      # No GELF host set — fall back to console logger.
      config :logger, backends: [:console]
  end

  # --- libcluster (single-node by default; opt in via RC_CLUSTER_DNS) -------
  case System.get_env("RC_CLUSTER_DNS") do
    query when is_binary(query) and query != "" ->
      config :libcluster,
        topologies: [
          rc_servers: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: query,
              node_basename: System.get_env("RC_CLUSTER_BASENAME") || "rc"
            ]
          ]
        ]

    _ ->
      config :libcluster, topologies: []
  end
end
