defmodule CrewCache.Config do
  @moduledoc """
  crew_cache's static settings: the application environment
  (`config/runtime.exs` fills it from `CREW_*` variables, §21.3)
  overridden by the options given to `CrewCache.start_link/1`.

  | Key | Default | |
  |---|---|---|
  | `dir` | required | The cache directory (`${CREW_DATA_DIR}/cache`) |
  | `mode` | `:box` | `:parent` isn't built |
  | `listen` | `{10, 199, 0, 1}` | Registry, health and DNS address |
  | `https_port`, `http_port`, `dns_port` | 443, 80, 53 | 0 picks a free port |
  | `registry`, `dns` | true | false leaves that part out |
  | `mgmt` | `{{127, 0, 0, 1}, 7780}` | nil leaves management out |
  | `mgmt_token` | nil | Required when `mgmt` isn't on loopback |
  | `max_bytes` | 25% of the disk holding `dir` | The store's quota |
  | `dns_upstreams` | 1.1.1.1, 9.9.9.9 | `{ip, port}` |
  | `extra_blocked` | `[]` | CIDRs added to site4 |
  | `site4` | `[]` | Initial site4 CIDRs (the agent pushes the rest) |
  | `tag_ttl_ms` | 60000 | The tag micro-cache (§15.3) |
  | `parent_first_byte_ms` | 5000 | How long the parent gets (§15.7) |

  For tests only, and never set by `config/runtime.exs`: `net_except`
  (loopback CIDRs the address policy lets through), `resolve` (a map of
  names to addresses used instead of DNS), `origins` (compiled hosts
  mapped to a fake's `host:port`), `upstream_cacerts` (the fake's CA)
  and `host_root` (where `GET /host` reads `/run` and `/proc`).
  """

  defstruct dir: nil,
            mode: :box,
            listen: {10, 199, 0, 1},
            https_port: 443,
            http_port: 80,
            dns_port: 53,
            registry: true,
            dns: true,
            mgmt: {{127, 0, 0, 1}, 7780},
            mgmt_token: nil,
            max_bytes: nil,
            dns_upstreams: [{{1, 1, 1, 1}, 53}, {{9, 9, 9, 9}, 53}],
            extra_blocked: [],
            site4: [],
            tag_ttl_ms: 60_000,
            parent_first_byte_ms: 5_000,
            net_except: [],
            resolve: nil,
            origins: %{},
            upstream_cacerts: nil,
            host_root: "/"

  @type t :: %__MODULE__{}

  defimpl Inspect do
    def inspect(config, opts) do
      config
      |> Map.from_struct()
      |> Map.update!(:mgmt_token, &if(&1, do: "**redacted**"))
      |> Map.drop([:upstream_cacerts])
      |> Inspect.Map.inspect(opts)
    end
  end

  @doc "The application environment merged with `opts`, checked."
  @spec new(keyword) :: {:ok, t} | {:error, String.t()}
  def new(opts) do
    env = Application.get_all_env(:crew_cache) |> Keyword.take(keys())
    config = struct(__MODULE__, Keyword.merge(env, Keyword.take(opts, keys())))

    cond do
      not is_binary(config.dir) ->
        {:error, "the cache directory isn't set (CREW_CACHE_DIR or CREW_DATA_DIR)"}

      config.mode != :box ->
        {:error, "CREW_CACHE_MODE=#{config.mode} isn't supported: only box mode is built"}

      config.mgmt != nil and not loopback?(elem(config.mgmt, 0)) and
          config.mgmt_token in [nil, ""] ->
        {:error, "CREW_CACHE_MGMT_TOKEN is required when management listens off loopback"}

      true ->
        {:ok, %{config | max_bytes: config.max_bytes || default_max_bytes(config.dir)}}
    end
  end

  defp keys, do: Map.keys(%__MODULE__{}) -- [:__struct__]

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # §12.4: 25% of the data disk. `df` is asked once at start; without an
  # answer the quota is 10 GiB.
  defp default_max_bytes(dir) do
    File.mkdir_p(dir)

    with {out, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_, line | _] <- String.split(out, "\n", trim: true),
         [_, total | _] <- String.split(line),
         {kib, ""} <- Integer.parse(total) do
      div(kib * 1024, 4)
    else
      _ -> 10 * 1024 * 1024 * 1024
    end
  rescue
    _ -> 10 * 1024 * 1024 * 1024
  end

  @doc "The running cache's config."
  def get, do: :persistent_term.get(__MODULE__)

  @doc false
  def put(config), do: :persistent_term.put(__MODULE__, config)
end
