defmodule CrewWeb.ClientIP do
  @moduledoc """
  The address a request really came from, for rate limits and logs.

  The control plane usually sits on loopback behind `tailscale serve`,
  so every request's peer is 127.0.0.1. The proxy appends the client's
  address to `X-Forwarded-For`; that last entry is trusted, but only when
  the peer is loopback. Anyone else could send whatever header they like.
  """

  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(%Plug.Conn{remote_ip: ip, req_headers: headers}), do: resolve(ip, headers)

  @spec from_connect_info(map()) :: String.t()
  def from_connect_info(%{peer_data: %{address: ip}} = info),
    do: resolve(ip, info[:x_headers] || [])

  def from_connect_info(_), do: "unknown"

  @spec resolve(:inet.ip_address(), [{String.t(), String.t()}]) :: String.t()
  def resolve(peer, headers) do
    with true <- loopback?(peer),
         {:ok, forwarded} <- last_forwarded(headers) do
      forwarded |> :inet.ntoa() |> to_string()
    else
      _ -> peer |> :inet.ntoa() |> to_string()
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: Bitwise.bsr(a, 8) == 127
  defp loopback?(_), do: false

  defp last_forwarded(headers) do
    value =
      Enum.find_value(headers, fn {k, v} -> String.downcase(k) == "x-forwarded-for" && v end)

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
