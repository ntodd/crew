defmodule CrewCache.Supervisor do
  @moduledoc """
  The cache's processes, in start order: counters, the store, the CA,
  the settings (and with them the address policy), the upstream client,
  the fetchers, then whichever listeners are configured: the registry
  (HTTPS, and plain HTTP for `/healthz`), DNS and management.
  """
  use Supervisor

  alias CrewCache.{CA, Config, Settings, Stats, Store}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config =
      case Config.new(opts) do
        {:ok, config} -> config
        {:error, message} -> raise ArgumentError, "crew_cache: " <> message
      end

    File.mkdir_p!(config.dir)
    Config.put(config)

    children =
      [
        Stats,
        {Store, dir: config.dir, max_bytes: config.max_bytes},
        {CA, dir: config.dir, ip: config.listen},
        {Settings, config},
        CrewCache.Upstream.Memo,
        Supervisor.child_spec({Finch, name: CrewCache.Finch, pools: %{default: pool(config)}},
          id: :upstream_pool
        ),
        CrewCache.Parent,
        {Registry, keys: :unique, name: CrewCache.Fetcher.Registry},
        {DynamicSupervisor,
         name: CrewCache.Fetcher.Supervisor,
         strategy: :one_for_one,
         max_children: config.max_fetches}
      ] ++ registry(config) ++ dns(config) ++ mgmt(config)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # One pool per upstream host (Finch keys pools by origin), every
  # connection dialled through CrewCache.Dial, TLS verified against the
  # system trust store.
  defp pool(config) do
    cacerts = config.upstream_cacerts || :public_key.cacerts_get()

    [
      size: 16,
      count: 1,
      conn_opts: [transport_opts: [tcp_module: CrewCache.Dial, cacerts: cacerts, timeout: 10_000]]
    ]
  end

  defp registry(%{registry: false}), do: []

  defp registry(config) do
    %{certfile: certfile, keyfile: keyfile} = CA.files(config.dir)

    https =
      Supervisor.child_spec(
        {Bandit,
         plug: CrewCache.Registry,
         scheme: :https,
         ip: config.listen,
         port: config.https_port,
         startup_log: false,
         thousand_island_options: [
           num_acceptors: 16,
           num_connections: 4096,
           transport_options: [
             certfile: certfile,
             keyfile: keyfile,
             versions: [:"tlsv1.3", :"tlsv1.2"]
           ]
         ]},
        id: :registry_https
      )

    http =
      Supervisor.child_spec(
        {Bandit,
         plug: CrewCache.Registry.Health,
         scheme: :http,
         ip: config.listen,
         port: config.http_port,
         startup_log: false},
        id: :registry_http
      )

    [https | if(config.http_port, do: [http], else: [])]
  end

  defp dns(%{dns: false}), do: []
  defp dns(config), do: [{CrewCache.DNS, config}]

  defp mgmt(%{mgmt: nil}), do: []

  defp mgmt(%{mgmt: {ip, port}} = config) do
    [
      Supervisor.child_spec(
        {Bandit,
         plug: {CrewCache.Mgmt, token: config.mgmt_token},
         scheme: :http,
         ip: ip,
         port: port,
         startup_log: false},
        id: :mgmt
      )
    ]
  end
end
