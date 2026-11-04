defmodule CrewCache.Env do
  @moduledoc """
  crew_cache's variables (§21.3, from `${CREW_DATA_DIR}/cache/env`), as
  `config/runtime.exs` reads them in a release:

  | Variable | Default | |
  |---|---|---|
  | `CREW_CACHE_DIR` | `${CREW_DATA_DIR}/cache` (`/srv/crew/cache`) | The store, index, CA and settings |
  | `CREW_CACHE_MODE` | `box` | `parent` isn't built, and is refused at start |
  | `CREW_CACHE_LISTEN` | `10.199.0.1` | Registry, `/healthz` and DNS |
  | `CREW_CACHE_HTTPS_PORT` | 443 | `off` leaves the registry out |
  | `CREW_CACHE_HTTP_PORT` | 80 | `/healthz` only; `off` leaves it out |
  | `CREW_CACHE_DNS_PORT` | 53 | `off` leaves the resolver out |
  | `CREW_DNS_UPSTREAMS` | `1.1.1.1,9.9.9.9` | Addresses, optionally `:port` |
  | `CREW_CACHE_MAX_GIB` | 25% of the disk | The store's quota |
  | `CREW_CACHE_MGMT_LISTEN` | `127.0.0.1:7780` | `off` leaves management out |
  | `CREW_CACHE_MGMT_TOKEN` | unset | Required off loopback |
  | `CREW_EXTRA_BLOCKED` | empty | CIDRs added to site4, as for the agent |

  A bad value raises at boot, naming the variable.
  """

  alias CrewCache.Net

  @doc "Application settings from an environment map."
  def config(env) do
    data = present(env["CREW_DATA_DIR"]) || "/srv/crew"
    https = port(env, "CREW_CACHE_HTTPS_PORT", 443)
    dns = port(env, "CREW_CACHE_DNS_PORT", 53)

    [
      dir: present(env["CREW_CACHE_DIR"]) || Path.join(data, "cache"),
      mode: mode(env["CREW_CACHE_MODE"]),
      listen: ip(env, "CREW_CACHE_LISTEN", {10, 199, 0, 1}),
      https_port: https || 443,
      registry: https != nil,
      http_port: port(env, "CREW_CACHE_HTTP_PORT", 80),
      dns_port: dns || 53,
      dns: dns != nil,
      dns_upstreams: upstreams(env["CREW_DNS_UPSTREAMS"]),
      max_bytes: max_bytes(env["CREW_CACHE_MAX_GIB"]),
      mgmt: mgmt(env["CREW_CACHE_MGMT_LISTEN"]),
      mgmt_token: present(env["CREW_CACHE_MGMT_TOKEN"]),
      extra_blocked: cidrs(env["CREW_EXTRA_BLOCKED"])
    ]
  end

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp bad!(var, value), do: raise(ArgumentError, "#{var}=#{inspect(value)} isn't valid")

  defp mode(value) do
    case present(value) do
      nil -> :box
      "box" -> :box
      "parent" -> :parent
      other -> bad!("CREW_CACHE_MODE", other)
    end
  end

  defp ip(env, var, default) do
    case present(env[var]) do
      nil -> default
      text -> parse_ip(text) || bad!(var, text)
    end
  end

  defp parse_ip(text) do
    case :inet.parse_ipv4strict_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp port(env, var, default) do
    case present(env[var]) do
      nil -> default
      "off" -> nil
      text -> parse_port(text) || bad!(var, text)
    end
  end

  defp parse_port(text) do
    case Integer.parse(text) do
      {n, ""} when n in 0..65_535 -> n
      _ -> nil
    end
  end

  defp upstreams(value) do
    case split(value) do
      [] -> [{{1, 1, 1, 1}, 53}, {{9, 9, 9, 9}, 53}]
      entries -> Enum.map(entries, &(host_port(&1, 53) || bad!("CREW_DNS_UPSTREAMS", value)))
    end
  end

  defp host_port(text, default_port) do
    case String.split(text, ":") do
      [ip] ->
        with ip when ip != nil <- parse_ip(ip), do: {ip, default_port}

      [ip, port] ->
        with ip when ip != nil <- parse_ip(ip), p when p != nil <- parse_port(port), do: {ip, p}

      _ ->
        nil
    end
  end

  defp max_bytes(value) do
    case present(value) do
      nil ->
        nil

      text ->
        case Float.parse(text) do
          {gib, ""} when gib > 0 -> trunc(gib * 1024 * 1024 * 1024)
          _ -> bad!("CREW_CACHE_MAX_GIB", text)
        end
    end
  end

  defp mgmt(value) do
    case present(value) do
      nil ->
        {{127, 0, 0, 1}, 7780}

      "off" ->
        nil

      text ->
        case String.split(text, ":") do
          [_, _] -> host_port(text, nil) || bad!("CREW_CACHE_MGMT_LISTEN", text)
          _ -> bad!("CREW_CACHE_MGMT_LISTEN", text)
        end
    end
  end

  defp cidrs(value) do
    for entry <- split(value) do
      case Net.parse_cidr(entry) do
        {:ok, _} -> entry
        :error -> bad!("CREW_EXTRA_BLOCKED", value)
      end
    end
  end

  defp split(nil), do: []

  defp split(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
