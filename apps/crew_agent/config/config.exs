import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:op_id, :vm_id]

import_config "#{config_env()}.exs"
