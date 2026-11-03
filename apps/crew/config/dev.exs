import Config

if System.get_env("CREW_DB", "sqlite") == "postgres" do
  config :crew, Crew.Repo,
    url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/crew_dev"),
    pool_size: 10,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true
else
  config :crew, Crew.Repo,
    database: System.get_env("CREW_DEV_DATABASE", Path.expand("../crew_dev.db", __DIR__)),
    pool_size: 5,
    stacktrace: true,
    show_sensitive_data_on_connection_error: true
end

# Queries are logged only when asked for: the agent's metrics every 5 s
# drown everything else.
config :crew, Crew.Repo, log: if(System.get_env("CREW_SQL_LOG"), do: :debug, else: false)

config :crew, CrewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "KnVlzRzbuwXMtwZ9q7Ny6W4ZLdnrSK8pOgyoAfFc45RURnXHEwhUAE2vEWxn5wnN",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:crew, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:crew, ~w(--watch)]}
  ]

# Development-only encryption key for secrets at rest. Never used in prod.
config :crew, Crew.Vault,
  ciphers: [
    default:
      {Crew.Vault.Cipher,
       tag: "AES.GCM.V1",
       keys: [Base.decode64!("3Jnb0hZiHIhHCOH6yX8mAh6s0b3o8TfA6cZJ3dzBnS8=")],
       iv_length: 12}
  ]

# Dev-only routes: the LiveDashboard, Oban Web and a login that skips GitHub.
config :crew, dev_routes: true

config :logger, :default_formatter, format: "[$level] $metadata$message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
