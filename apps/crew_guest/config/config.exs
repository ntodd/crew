import Config

# The boot sequence starts with the application, except in tests, which
# start the pieces they need.
config :crew_guest, autostart: config_env() != :test

config :logger, :default_formatter, format: "$time [$level] $message\n"

if config_env() == :test do
  config :logger, level: :warning
end
