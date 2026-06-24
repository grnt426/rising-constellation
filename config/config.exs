# Base configuration loaded in every environment. Values here are dev/test
# defaults — production overrides come from `config/runtime.exs` reading env
# vars at release boot. See DEPLOYMENT.md and .env.example.

import Config

config :rc,
  ecto_repos: [RC.Repo],
  rc_domain: "http://localhost:4000/",
  support_email: "support@localhost",
  environment: Mix.env(),
  signup_mode: :mail_validation,
  login_mode: :enabled,
  revision: "dev"

# Configures the endpoint
config :rc, Portal.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "fGMm7d69BXjFMZLa/yODsyLCc5HoWpS+NA2BWnzE7qrII/472koYz2R1N1QGbAw2",
  render_errors: [view: Portal.ErrorView, accepts: ~w(json)],
  pubsub_server: RC.PubSub,
  live_view: [signing_salt: "Fk5non4L0-gW1UuE"]

config :rc, RC.Guardian,
  issuer: "rc",
  secret_key: "SKo7gza6mEz1XuYADSxIKBB8sbTyAkxwPyCib1qvo7Q7MHJxe+XeV4wahPEbacie",
  # Short access + long refresh. Access tokens are the bearer credential the
  # SPA/socket/bots present on every request; refresh tokens are accepted
  # only at POST /api/auth/refresh and swapped for a fresh access token. Both
  # carry the `tv` claim — RC.Accounts.invalidate_sessions/1 (on logout /
  # password change / ban) kills both kinds at once.
  token_ttl: %{
    "access" => {4, :hour},
    "refresh" => {30, :day}
  }

# Dev/test mailer defaults. Prod credentials + sender come from
# config/runtime.exs (MAILER_* env vars).
config :rc, RC.Mailer,
  adapter: Swoosh.Adapters.Mailjet,
  api_key: "my-api-key",
  secret: "my-wonderful-secret",
  sender: {"Tetrarchy Falls", "support@localhost"},
  verification_template: 1_352_021,
  password_reset_template: 1_363_520,
  email_update_template: 1_699_096,
  web_bind_template: 3_028_081

config :rc, RC.Accounts.AccountToken,
  validity_time: 7200,
  length: 32

config :rc, RC.Accounts.Profile,
  limit: 2

config :rc, RC.Groups,
  blog_group_name: "blog-writers",
  reserved_names: ~w(blog-writers admin)

config :rc, RC.Uploader,
  valid_image_extensions: ~w(.jpg .jpeg .gif .png),
  max_image_size: 50_000_000

config :rc, RC.Uploader.StandardFile,
  path: "files/"

config :rc, RC.Uploader.ImageFile,
  path: "images/"

config :rc, RC.Uploader.ThumbnailFile,
  path: "thumbnails/"

# Hammer (rate limiter). ETS backend is in-process, so limits are per-node;
# acceptable for a small community deployment, swap for a shared backend
# (Redis/Mnesia) if we ever scale horizontally.
config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configures Ueberauth
config :ueberauth, Ueberauth,
  base_path: "/api/auth",
  providers: [
    identity:
      {Ueberauth.Strategy.Identity,
       [
         callback_methods: ["POST"],
         nickname_field: :email,
         param_nesting: "account",
         uid_field: :email
       ]}
  ]

# Setup appsignal
config :appsignal, :config,
  otp_app: :rc,
  name: "rising-constellation",
  push_api_key: "",
  env: Mix.env(),
  active: false,
  ignore_actions: ["Query RC.Repo"]

# disable elixir_google_spreadsheets by default, we only need it in dev for now
config :goth,
  disabled: true

config :elixir_google_spreadsheets,
  spreadsheet_id: ""

config :elixir_google_spreadsheets, :client, request_workers: 1

config :waffle,
  storage: Waffle.Storage.Local,
  # in order to have a different storage directory from url
  storage_dir: "priv/storage/",
  asset_host: "localhost"

config :stripity_stripe,
  api_key:
    "sk_test_51HErywBV7j6S5TKAnjMvPr5jX8jRuyFqW03HHq10H3CPyeHviMh16npdVzi1tPt7N8o4vXVLlh5Rcbzkfh5l41sG00j3IWkFEl",
  public_key:
    "pk_test_51HErywBV7j6S5TKAnvkvZQ9s01YkfnPFdVQi3haVBfBhYZslueyL8ROgi2MVQOpjfwinBWlWUxwwSL2SYuCI4lEc00kvJ6QS2T"

# configure reserved names for folders
config :rc, RC.Scenarios.Folder,
  scenario_likes_name: "scenario-likes",
  scenario_dislikes_name: "scenario-dislikes",
  scenario_favorites_name: "scenario-favorites"

config :libcluster,
  topologies: [
    rc_servers: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"node_1@127.0.0.1", :"node_2@127.0.0.1"]]
    ]
  ]

config :rc, RC.SystemAI,
  path: "data/system_ai/behavior_tree.json",
  name: "Dominion"

# Content-memory model for serving game data (see Data.Data). :legacy copies
# the ~130KB content map onto each caller's heap per Querier lookup (original
# behaviour); :shared serves it zero-copy from persistent_term. Defaults to
# :legacy so deploying is a no-op until deliberately flipped (per-instance via
# Data.Data.switch_memory_mode/2, globally via Data.Data.set_memory_mode/1, or
# at boot via the RC_DATA_MEMORY_MODE env var — see config/runtime.exs).
config :rc, :data_memory_mode, :legacy

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
