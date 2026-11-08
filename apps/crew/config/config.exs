import Config

# The control plane's database: SQLite (the default, one file next to the
# app) or Postgres. Chosen at compile time, because Ecto fixes a repo's
# adapter when the repo compiles; a release is built for one or the other.
#
#     CREW_DB=postgres mix compile
database = System.get_env("CREW_DB", "sqlite")

unless database in ["sqlite", "postgres"] do
  raise "CREW_DB must be sqlite or postgres, got #{inspect(database)}"
end

config :crew,
  database: database,
  ecto_repos: [Crew.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

config :crew, Crew.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

# SQLite: transactions take the write lock when they begin. A deferred
# one that reads and then writes fails at once ("database busy", which
# busy_timeout doesn't cover) if anything else wrote in between. Taking
# the lock up front means writers queue instead, so give them longer than
# the 2s default before an agent channel gives up and reconnects.
#
# exqlite applies busy_timeout after journal_mode and the other pragmas, so
# a connection opened while another writes would fail to connect ("database
# is locked") and be retried; as the first pragma it waits instead.
if database == "sqlite" do
  config :crew, Crew.Repo,
    default_transaction_mode: :immediate,
    busy_timeout: 15_000,
    custom_pragmas: [busy_timeout: 15_000]
end

config :crew, Oban,
  engine: if(database == "sqlite", do: Oban.Engines.Lite, else: Oban.Engines.Basic),
  notifier: if(database == "sqlite", do: Oban.Notifiers.PG, else: Oban.Notifiers.Postgres),
  repo: Crew.Repo,
  # §9.3
  queues: [hooks: 10, github: 5, reconcile: 1, maintenance: 1, images: 1, default: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # §18.1: every six hours, as well as at every token refresh.
       {"41 */6 * * *", Crew.Jobs.CheckAccess},
       # §18.3: members' repo access, every 30 minutes.
       {"*/30 * * * *", Crew.Repos.AccessWorker},
       {"*/15 * * * *", Crew.Repos.SyncWorker},
       # §6.2: missed deliveries.
       {"*/5 * * * *", Crew.GitHub.Redeliver},
       # §6.3: runners left behind.
       {"*/10 * * * *", Crew.GitHub.RunnerGC},
       # §9.4: log retention and the total cap.
       {"17 * * * *", Crew.Logs.Prune},
       # §9.4: box, VM and cache samples, 7 days.
       {"47 * * * *", Crew.Metrics.Prune},
       # §16.6: closed days' usage, kept forever.
       {"53 * * * *", Crew.Usage.Rollup},
       # §13.1: actions/runner's releases, for the runner's freshness.
       {"23 4 * * *", Crew.Images.Runner},
       # §20.4: the control plane's image files, checked and kept in bounds.
       {"37 4 * * *", Crew.Images.Upkeep},
       # §20.3: a newer Crew release, for the Deployment page.
       {"11 5 * * *", Crew.Updates.Check},
       # §20.2: agent updates under way settle, and due ones go out.
       {"* * * * *", Crew.Agents.UpdateSweep},
       # §12.1: pending reboots' commands, until the new boot shows up.
       {"* * * * *", Crew.Boxes.RebootSweep}
     ]}
  ]

config :crew, CrewWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CrewWeb.ErrorHTML, json: CrewWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Crew.PubSub,
  live_view: [signing_salt: "ayoi0W5m"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  crew: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  crew: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :env_id, :op_id, :box_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
