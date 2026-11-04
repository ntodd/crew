import Config

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

# The release starts the cache from its environment (runtime.exs). In
# development and tests, start `{CrewCache, opts}` yourself.
config :crew_cache, autostart: config_env() == :prod

import_config "#{config_env()}.exs"
