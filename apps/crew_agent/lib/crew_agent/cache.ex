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

  alias CrewAgent.Config

  @no_cache {:error, "no_cache", "this box has no registry cache configured"}

  @doc "The cache's root certificate, or `{:error, reason}` when there's no cache."
  def ca_pem(%Config{cache_mgmt_url: nil}), do: {:error, :no_cache}

  def ca_pem(%Config{} = config) do
    case request(config, :get, "/ca.pem") do
      {:ok, %{status: 200, body: pem}} when is_binary(pem) -> {:ok, pem}
      other -> {:error, other}
    end
  end

  @doc "Passes `cache.config` on, and remembers the enabled hosts for the guests' mirrors."
  def configure(%Config{cache_mgmt_url: nil}, _payload), do: @no_cache

  def configure(%Config{} = config, payload) do
    body = %{
      enabled_hosts: payload.enabled_hosts,
      allowlist: Map.get(payload, :allowlist, []),
      parent: Map.get(payload, :parent),
      rotate_ca: Map.get(payload, :rotate_ca, false)
    }

    case request(config, :post, "/config", json: body) do
      {:ok, %{status: 200}} ->
        File.mkdir_p!(Path.dirname(state_file(config)))
        state = Jason.encode!(%{enabled_hosts: body.enabled_hosts})
        CrewAgent.SafeFS.write_atomic(state_file(config), state, 0o640)

      other ->
        {:error, "cache_failed", "the cache didn't take its config: #{describe(other)}"}
    end
  end

  @doc "Passes `cache.purge` on (`all`, `host:<host>` or `repo:<host>/<repository>`)."
  def purge(%Config{cache_mgmt_url: nil}, _scope), do: @no_cache

  def purge(%Config{} = config, scope) do
    case request(config, :post, "/purge", json: %{scope: scope}) do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, "cache_failed", "the cache didn't purge: #{describe(other)}"}
    end
  end

  @doc "The cache's cumulative counters (`GET /stats`), or an error."
  def stats(%Config{cache_mgmt_url: nil}), do: {:error, :no_cache}

  def stats(%Config{} = config) do
    case request(config, :get, "/stats") do
      {:ok, %{status: 200, body: %{} = stats}} -> {:ok, stats}
      other -> {:error, other}
    end
  end

  @doc "The registries guests pull through the cache: what the last `cache.config` enabled."
  def mirrors(%Config{cache_mgmt_url: nil}), do: []

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
      [
        method: method,
        url: config.cache_mgmt_url <> path,
        headers: headers,
        retry: false,
        receive_timeout: 10_000
      ] ++
        opts
    )
  rescue
    e -> {:error, e}
  end

  defp describe({:ok, %{status: status}}), do: "HTTP #{status}"
  defp describe({:error, %{__exception__: true} = e}), do: Exception.message(e)
  defp describe(other), do: inspect(other)
end
