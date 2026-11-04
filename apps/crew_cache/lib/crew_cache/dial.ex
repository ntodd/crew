defmodule CrewCache.Dial do
  @moduledoc """
  The `tcp_module` (see `:gen_tcp.connect/4`) every upstream connection
  goes through, TLS or not: `gen_tcp` asks it for the name's addresses,
  so names resolve through `CrewCache.Resolver` and blocked4 and site4
  are refused for the upstream and for every redirect target alike.
  Each address is checked again as it's dialled.

  Finch's pools and Mint's TLS (SNI, hostname verification against the
  system trust store) work unchanged above it.
  """

  require Logger

  alias CrewCache.{Net, Resolver}

  def getaddrs(address, _timer) do
    case Resolver.addresses(address) do
      {:ok, ips} ->
        {:ok, ips}

      {:error, {:refused, ips}} ->
        Logger.warning(
          "refused to connect to #{name(address)}: #{Enum.map_join(ips, ", ", &ntoa/1)} " <>
            "is in blocked4 or site4"
        )

        {:error, :eacces}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connect(ip, port, opts, timeout) do
    if Net.refused?(ip, Net.current()) do
      Logger.warning("refused to connect to #{ntoa(ip)}: it's in blocked4 or site4")
      {:error, :eacces}
    else
      :inet_tcp.connect(ip, port, opts, timeout)
    end
  end

  defdelegate getserv(port), to: :inet_tcp
  defdelegate family(), to: :inet_tcp

  defp name(address) when is_tuple(address), do: ntoa(address)
  defp name(address), do: to_string(address)

  defp ntoa(ip), do: ip |> :inet.ntoa() |> to_string()
end
