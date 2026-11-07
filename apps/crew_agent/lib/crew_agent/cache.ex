defmodule CrewAgent.Cache do
  @moduledoc """
  The box's registry cache (§15), through its management endpoint
  (§15.8, `CREW_CACHE_MGMT_URL`, with `CREW_CACHE_MGMT_TOKEN` as a bearer
  when set). The control plane's `cache.config` and `cache.purge` are
  passed on; the hosts the cache serves are kept in `agent/cache.json`,
  so every guest's payload names them as its mirrors (§15.1, Design A).
  The CA root it reports goes into every payload too, as the trust
  anchor for the cache's certificates.
  """

  alias CrewAgent.{CacheVM, Config}

  @no_cache {:error, "no_cache", "this box has no registry cache configured"}

  @doc "Whether this box has a cache: `CREW_CACHE_MGMT_URL`, or a cache VM on a Mac."
  @spec present?(Config.t()) :: boolean()
  def present?(%Config{cache_mgmt_url: url}) when is_binary(url) and url != "", do: true
  def present?(%Config{} = config), do: CacheVM.configured?(config)

  @doc "The cache's root certificate, or `{:error, reason}` when there's no cache."
  def ca_pem(%Config{cache_mgmt_url: nil} = config) do
    if url = CacheVM.mgmt_url(config),
      do: ca_pem(%{config | cache_mgmt_url: url}),
      else: {:error, :no_cache}
  end

  def ca_pem(%Config{} = config) do
    case request(config, :get, "/ca.pem") do
      {:ok, %{status: 200, body: pem}} when is_binary(pem) -> {:ok, pem}
      other -> {:error, other}
    end
  end

  @doc "Passes `cache.config` on, and remembers the enabled hosts for the guests' mirrors."
  def configure(%Config{cache_mgmt_url: nil} = config, payload) do
    if url = CacheVM.mgmt_url(config),
      do: configure(%{config | cache_mgmt_url: url}, payload),
      else: @no_cache
  end

  def configure(%Config{} = config, payload) do
    body = %{
      enabled_hosts: payload.enabled_hosts,
      allowlist: Map.get(payload, :allowlist, []),
      rotate_ca: Map.get(payload, :rotate_ca, false),
      # The box's networks and egress address: the cache refuses to
      # connect to them (§15.5), as job VMs are refused them.
      site4: CrewAgent.Site.current(config)
    }

    # The control plane doesn't serve a parent cache yet (§15.7): one
    # the cache was given some other way stays unless a parent is sent.
    body = if parent = Map.get(payload, :parent), do: Map.put(body, :parent, parent), else: body

    case request(config, :post, "/config", json: body) do
      {:ok, %{status: 200}} ->
        File.mkdir_p!(Path.dirname(state_file(config)))
        state = Jason.encode!(%{enabled_hosts: body.enabled_hosts})
        CrewAgent.SafeFS.write_atomic(state_file(config), state, 0o640)

      other ->
        {:error, "cache_failed", "the cache didn't take its config: #{describe(other)}"}
    end
  end

  @doc "Tells the cache the box's site4 alone (§15.5); its other settings stay."
  def put_site4(%Config{cache_mgmt_url: nil} = config, site4) do
    if url = CacheVM.mgmt_url(config),
      do: put_site4(%{config | cache_mgmt_url: url}, site4),
      else: {:error, :no_cache}
  end

  def put_site4(%Config{} = config, site4) do
    case request(config, :post, "/config", json: %{site4: site4}) do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, describe(other)}
    end
  end

  @doc "Passes `cache.purge` on (`all`, `host:<host>` or `repo:<host>/<repository>`)."
  def purge(%Config{cache_mgmt_url: nil} = config, scope) do
    if url = CacheVM.mgmt_url(config),
      do: purge(%{config | cache_mgmt_url: url}, scope),
      else: @no_cache
  end

  def purge(%Config{} = config, scope) do
    case request(config, :post, "/purge", json: %{scope: scope}) do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, "cache_failed", "the cache didn't purge: #{describe(other)}"}
    end
  end

  @doc "The cache's cumulative counters (`GET /stats`), or an error."
  def stats(%Config{cache_mgmt_url: nil} = config) do
    if url = CacheVM.mgmt_url(config),
      do: stats(%{config | cache_mgmt_url: url}),
      else: {:error, :no_cache}
  end

  def stats(%Config{} = config) do
    case request(config, :get, "/stats") do
      {:ok, %{status: 200, body: %{} = stats}} -> {:ok, stats}
      other -> {:error, other}
    end
  end

  @doc "The cache host's reboot state (`GET /host`, §12.1): what a cache VM reports."
  def host(%Config{cache_mgmt_url: nil} = config) do
    if url = CacheVM.mgmt_url(config),
      do: host(%{config | cache_mgmt_url: url}),
      else: {:error, :no_cache}
  end

  def host(%Config{} = config) do
    case request(config, :get, "/host", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{} = host}} -> {:ok, host}
      other -> {:error, other}
    end
  end

  @doc "The registries guests pull through the cache: what the last `cache.config` enabled."
  def mirrors(%Config{cache_mgmt_url: nil} = config) do
    if url = CacheVM.mgmt_url(config),
      do: mirrors(%{config | cache_mgmt_url: url}),
      else: []
  end

  def mirrors(%Config{} = config) do
    with {:ok, json} <- File.read(state_file(config)),
         {:ok, %{"enabled_hosts" => hosts}} when is_list(hosts) <- Jason.decode(json) do
      hosts
    else
      _ -> []
    end
  end

  defp state_file(config), do: Path.join([config.data_dir, "agent", "cache.json"])

  defp request(config, method, path, opts \\ []) do
    headers =
      if config.cache_mgmt_token,
        do: [{"authorization", "Bearer " <> config.cache_mgmt_token}],
        else: []

    Req.request(
      Keyword.merge(
        [
          method: method,
          url: config.cache_mgmt_url <> path,
          headers: headers,
          retry: false,
          receive_timeout: 10_000
        ],
        opts
      )
    )
  rescue
    e -> {:error, e}
  end

  defp describe({:ok, %{status: status}}), do: "HTTP #{status}"
  defp describe({:error, %{__exception__: true} = e}), do: Exception.message(e)
  defp describe(other), do: inspect(other)
end
