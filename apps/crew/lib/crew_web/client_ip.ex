defmodule CrewWeb.ClientIP do
  @moduledoc """
  The address a request really came from, for rate limits and logs.

  The control plane usually sits on loopback behind `tailscale serve`,
  so every request's peer is 127.0.0.1. The proxy appends the client's
  address to `X-Forwarded-For`; that last entry is trusted, but only when
  the peer is loopback, or in a range `CREW_TRUSTED_PROXIES` names (under
  `docker/compose.yml`, the peer is Docker's bridge gateway). Anyone else
  could send whatever header they like.
  """

  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(%Plug.Conn{remote_ip: ip, req_headers: headers}), do: resolve(ip, headers)

  @spec from_connect_info(map()) :: String.t()
  def from_connect_info(%{peer_data: %{address: ip}} = info),
    do: resolve(ip, info[:x_headers] || [])

  def from_connect_info(_), do: "unknown"

  @spec resolve(:inet.ip_address(), [{String.t(), String.t()}]) :: String.t()
  def resolve(peer, headers) do
    with true <- loopback?(peer) or trusted?(peer),
         {:ok, forwarded} <- last_forwarded(headers) do
      forwarded |> :inet.ntoa() |> to_string()
    else
      _ -> peer |> :inet.ntoa() |> to_string()
    end
  end

  defp trusted?(peer) do
    peer = unmap(peer)
    Enum.any?(Crew.Config.trusted_proxies(), &in_cidr?(peer, &1))
  end

  # An IPv4 peer on an IPv6 socket (::ffff:a.b.c.d) is its IPv4 address.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: {Bitwise.bsr(a, 8), Bitwise.band(a, 0xFF), Bitwise.bsr(b, 8), Bitwise.band(b, 0xFF)}

  defp unmap(ip), do: ip

  defp in_cidr?(ip, {net, bits}) when tuple_size(ip) == tuple_size(net) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    shift = width - bits
    Bitwise.bsr(to_int(ip), shift) == Bitwise.bsr(to_int(net), shift)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp to_int({a, b, c, d}), do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d

  defp to_int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, fn x, acc -> Bitwise.bsl(acc, 16) + x end)

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: Bitwise.bsr(a, 8) == 127
  defp loopback?(_), do: false

  defp last_forwarded(headers) do
    # The last field, as a proxy that appends a field of its own adds it
    # after whatever the client sent.
    value =
      headers
      |> Enum.filter(fn {k, _} -> String.downcase(k) == "x-forwarded-for" end)
      |> List.last()
      |> case do
        {_, v} -> v
        nil -> nil
      end

    with value when is_binary(value) <- value,
         true <- String.valid?(value),
         last when last != "" <- value |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(last)) do
      {:ok, ip}
    else
      _ -> :error
    end
  end
end
