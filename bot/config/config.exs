import Config

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:bot_id, :stage]

import_config "#{config_env()}.exs"
