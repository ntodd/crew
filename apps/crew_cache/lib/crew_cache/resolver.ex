defmodule CrewCache.Resolver do
  @moduledoc """
  How the cache finds an upstream's (or a redirect target's) addresses:
  A records from `CREW_DNS_UPSTREAMS`, never the host's resolver (which
  could be a LAN router or MagicDNS), with every answer in blocked4 or
  site4 dropped (§15.3). IPv4 only.

  Tests give a fixed map instead (`CrewCache.Config` `resolve`); with a
  map, a name it doesn't have doesn't resolve.
  """

  alias CrewCache.{Config, Net}

  @timeout 3_000

  @doc """
  The addresses the cache may connect to for `host`: `{:ok, ips}`,
  `{:error, {:refused, ips}}` when every answer is blocked, or
  `{:error, reason}`.
  """
  def addresses(host, config \\ Config.get(), policy \\ Net.current())

  def addresses({_, _, _, _} = ip, _config, policy), do: check([ip], policy)
  def addresses({_, _, _, _, _, _, _, _} = ip, _config, _policy), do: {:error, {:refused, [ip]}}

  def addresses(host, config, policy) when is_list(host),
    do: addresses(List.to_string(host), config, policy)

  def addresses(host, config, policy) when is_binary(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        addresses(ip, config, policy)

      {:error, _} ->
        with {:ok, ips} <- lookup(String.downcase(host), config), do: check(ips, policy)
    end
  end

  defp lookup(host, %{resolve: map}) when is_map(map) do
    case Map.fetch(map, host) do
      {:ok, ips} -> {:ok, ips}
      :error -> {:error, :nxdomain}
    end
  end

  defp lookup(host, config) do
    case :inet_res.lookup(String.to_charlist(host), :in, :a,
           nameservers: config.dns_upstreams,
           timeout: @timeout,
           usevc: false
         ) do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end

  defp check(ips, policy) do
    case Enum.reject(ips, &Net.refused?(&1, policy)) do
      [] -> {:error, {:refused, ips}}
      allowed -> {:ok, allowed}
    end
  end
end
