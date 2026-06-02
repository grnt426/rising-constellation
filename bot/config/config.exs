import Config

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:bot_id, :stage]

# Driver-side admin endpoint. Binds on all interfaces (0.0.0.0) so that
# when the harness runs inside Docker the `-p 5500:5500` port mapping
# can reach it. The security boundary is "this is on YOUR machine; don't
# expose it publicly" — put nginx + basic auth in front if you ever
# run it on a multi-tenant box.
config :rc_bot, RcBot.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 5500],
  server: true,
  pubsub_server: RcBot.PubSub,
  live_view: [signing_salt: "rc_bot_driver_salt_change_me"],
  secret_key_base: "rc_bot_driver_secret_at_least_64_chars_long_xxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  render_errors: [formats: [html: RcBot.Web.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
