import Config

if System.get_env("CREW_DB", "sqlite") == "postgres" do
  config :crew, Crew.Repo,
    url:
      System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/crew_test") <>
        "#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
else
  config :crew, Crew.Repo,
    database: Path.expand("../crew_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
    pool_size: 5,
    # Each sandboxed test holds a transaction, which takes the write lock
    # when it begins (see config.exs); async tests wait for each other.
    busy_timeout: 30_000,
    pool: Ecto.Adapters.SQL.Sandbox
end

config :crew, Oban, testing: :manual

config :crew, image_req_options: [plug: {Req.Test, Crew.Images.Mirror}, retry: false]
config :crew, cache_req_options: [plug: {Req.Test, Crew.Caches}]
config :crew, tailscale_req_options: [plug: {Req.Test, Crew.Tailscale}, retry: false]

# Tests read the charts right after writing their rows.
config :crew, chart_cache_ms: 0

config :crew, CrewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e/Y5OfWQvLQ62yfWWoqWxf2uf5xbDAh/05h3jTT3BKyCPDKEikFPkDG7Xe2K4lFD",
  server: false

# The second key is a retired one, for the rotation tests.
config :crew, Crew.Vault,
  ciphers: [
    default:
      {Crew.Vault.Cipher,
       tag: "AES.GCM.V1",
       keys: [
         Base.decode64!("vT8f4ZpX3m2Qb9yR1sL0kW7cH5nJ6dA4eG2tU8iO3xM="),
         Base.decode64!("q1Zt8mR4bN7cW2xK9pL5vD3hF6jS0aG8eY4uT1iQ7oE=")
       ],
       iv_length: 12}
  ]

config :crew,
  env: :test,
  github_req_options: [plug: {Req.Test, Crew.GitHub}, retry: false],
  github_retry_ms: 1,
  agent_release_public_key: nil,
  # Tests check for releases through Req.Test, never at boot.
  update_check: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true,
  test_warnings: [missing_form_id: :raise]

config :phoenix, sort_verified_routes_query_params: true
config :crew, sync_dispatch: true
config :crew, log_dir: Path.expand("../tmp/test-logs", __DIR__)
config :crew, image_dir: Path.expand("../tmp/test-images", __DIR__)
config :crew, agent_store_dir: Path.expand("../tmp/test-agent-store", __DIR__)
