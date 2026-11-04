import Config

config :crew_agent,
  connect: false,
  driver: "null",
  dev: true,
  data_dir: Path.expand("../tmp/test-data", __DIR__),
  guest_api_port: 0

config :logger, level: :warning

# An agent.update in a test doesn't stop the test run.
config :crew_agent, exit_after_update: false
