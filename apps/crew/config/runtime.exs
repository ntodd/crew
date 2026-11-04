import Config

# Runtime configuration, read from the environment. See docs/setup/ for
# what each deployment sets.

list = fn name ->
  name |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

if System.get_env("PHX_SERVER") do
  config :crew, CrewWeb.Endpoint, server: true
end

# HTTP/1.1 only. Crew sits behind a TLS proxy and nothing it serves
# needs HTTP/2; see EEF-CVE-2026-105659 in mix.exs.
config :crew, CrewWeb.Endpoint,
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    http_2_options: [enabled: false]
  ]

if config_env() == :dev do
  config :crew, CrewWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"lib/crew_web/router\.ex$"E,
        ~r"lib/crew_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# Settings every environment reads (dev and prod), with defaults that suit
# a single-user personal deployment.
int = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> String.to_integer(String.trim(value))
  end
end

if config_env() != :test do
  webhooks = System.get_env("CREW_WEBHOOKS", "on")

  unless webhooks in ["on", "off"] do
    raise "CREW_WEBHOOKS must be on or off, got #{inspect(webhooks)}"
  end

  config :crew,
    admins: list.("CREW_ADMINS"),
    allowed_users: list.("CREW_ALLOWED_USERS"),
    allowed_org: System.get_env("CREW_ALLOWED_ORG"),
    release_public_key: System.get_env("CREW_RELEASE_PUBLIC_KEY"),
    agent_release_dir: System.get_env("CREW_AGENT_RELEASE_DIR"),
    github_app: %{
      app_id: System.get_env("CREW_GITHUB_APP_ID"),
      client_id: System.get_env("CREW_GITHUB_CLIENT_ID"),
      client_secret: System.get_env("CREW_GITHUB_CLIENT_SECRET"),
      private_key:
        System.get_env("CREW_GITHUB_PRIVATE_KEY") ||
          (System.get_env("CREW_GITHUB_PRIVATE_KEY_FILE") &&
             File.read!(System.get_env("CREW_GITHUB_PRIVATE_KEY_FILE"))),
      webhook_secret: System.get_env("CREW_GITHUB_WEBHOOK_SECRET")
    },
    tailscale: %{
      client_id: System.get_env("CREW_TAILSCALE_CLIENT_ID"),
      client_secret: System.get_env("CREW_TAILSCALE_CLIENT_SECRET"),
      tailnet: System.get_env("CREW_TAILSCALE_TAILNET", "-")
    },
    github_api_url: System.get_env("CREW_GITHUB_API_URL"),
    github_web_url: System.get_env("CREW_GITHUB_WEB_URL"),
    base_url: System.get_env("CREW_BASE_URL"),
    # §21.1
    dev: System.get_env("CREW_DEV") == "1",
    strict_csp: System.get_env("CREW_STRICT_CSP") == "1",
    hook_port: int.("CREW_HOOK_PORT", 4001),
    webhooks: webhooks == "on",
    idle_grace_s: int.("CREW_IDLE_GRACE", 30),
    idle_max_s: int.("CREW_IDLE_MAX", 600),
    job_max_s: int.("CREW_JOB_MAX", 22_500),
    log_limit_bytes: int.("CREW_LOG_LIMIT_BYTES", 104_857_600),
    log_dir:
      System.get_env(
        "CREW_LOG_DIR",
        if(config_env() == :dev,
          do: Path.expand("../../../tmp/logs", __DIR__),
          else: "/var/lib/crew/logs"
        )
      ),
    # §13.1, §20.1: the release's signed image manifests the control
    # plane's image carries, and where it keeps the files it mirrors.
    image_release_dir: System.get_env("CREW_IMAGE_RELEASE_DIR"),
    image_dir:
      System.get_env(
        "CREW_IMAGE_DIR",
        if(config_env() == :dev,
          do: Path.expand("../../../tmp/images", __DIR__),
          else: "/var/lib/crew/images"
        )
      ),
    log_max_gib: int.("CREW_LOG_MAX_GIB", 20),
    log_retention_days: int.("CREW_LOG_RETENTION_DAYS", 30),
    job_retention_days: int.("CREW_JOB_RETENTION_DAYS", 90),
    update_check: System.get_env("CREW_UPDATE_CHECK", "true") != "false",
    update_repo: System.get_env("CREW_UPDATE_REPO", "ntodd/crew"),
    update_dir: System.get_env("CREW_UPDATE_DIR", "/var/lib/crew-update")
end

if config_env() == :prod do
  # The release was compiled for one database (config.exs), and its repo
  # can only talk to that one, so the build decides, not the environment.
  database = Application.get_env(:crew, :database, "sqlite")

  runtime_db = System.get_env("CREW_DB", "")

  if runtime_db not in ["", database] do
    raise "CREW_DB is #{runtime_db}, but this release was built for #{database}; " <>
            "rebuild it with CREW_DB=#{runtime_db} or unset CREW_DB"
  end

  # The SQLite image started with a team's settings would come up healthy
  # on an empty database, and its tailnet sweep would delete every
  # environment's device.
  if database == "sqlite" and System.get_env("DATABASE_URL") not in [nil, ""] do
    raise "DATABASE_URL is set, but this release was built for SQLite; " <>
            "use the -pg image (or build with CREW_DB=postgres), or unset DATABASE_URL"
  end

  if database == "postgres" do
    url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is missing"
    host = URI.parse(url).host

    # TLS with certificate checks by default (Neon requires TLS).
    ssl =
      if System.get_env("DATABASE_SSL", "true") == "true" do
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host)
        ]
      else
        false
      end

    config :crew, Crew.Repo,
      url: url,
      ssl: ssl,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  else
    config :crew, Crew.Repo,
      database: System.get_env("DATABASE_PATH", "/var/lib/crew/crew.db"),
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing; generate one with: mix phx.gen.secret"

  # 32 random bytes, base64. Encrypts secrets, tokens and keys at rest.
  #     openssl rand -base64 32
  # A key of another length would boot and fail at the first encryption.
  decode_key = fn name, value ->
    case Base.decode64(String.trim(value)) do
      {:ok, <<_::binary-size(32)>> = key} ->
        key

      {:ok, key} ->
        raise "#{name} is #{byte_size(key)} bytes, not 32; " <>
                "generate one with: openssl rand -base64 32"

      :error ->
        raise "#{name} isn't base64; generate one with: openssl rand -base64 32"
    end
  end

  encryption_key =
    System.get_env("CREW_ENCRYPTION_KEY") ||
      raise "CREW_ENCRYPTION_KEY is missing; generate one with: openssl rand -base64 32"

  # Older keys, comma-separated, kept for reading while
  # Crew.Release.reencrypt() moves everything to the current one.
  retired_keys =
    System.get_env("CREW_ENCRYPTION_KEYS_RETIRED", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&decode_key.("CREW_ENCRYPTION_KEYS_RETIRED", &1))

  config :crew, Crew.Vault,
    ciphers: [
      default:
        {Crew.Vault.Cipher,
         tag: "AES.GCM.V1",
         keys: [decode_key.("CREW_ENCRYPTION_KEY", encryption_key) | retired_keys],
         iv_length: 12}
    ]

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is missing (the tailnet host name, e.g. crew.tail1234.ts.net)"

  # Listens on loopback by default: put `tailscale serve` in front of it
  # for HTTPS on the tailnet. Set CREW_LISTEN_IP to the box's tailnet
  # address to listen there directly instead.
  {:ok, ip} =
    System.get_env("CREW_LISTEN_IP", "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()

  config :crew,
    force_ssl: System.get_env("CREW_FORCE_SSL", "true") == "true",
    secure_cookies: System.get_env("CREW_SECURE_COOKIES", "true") == "true"

  config :crew, CrewWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: ip],
    check_origin: [
      "https://" <> host
      | String.split(System.get_env("CREW_EXTRA_ORIGINS", ""), ",", trim: true)
    ],
    secret_key_base: secret_key_base
end
