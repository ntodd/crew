defmodule CrewProtocol.IPv4 do
  @moduledoc "IPv4 addresses and prefixes used by a box's site filter."
  import Bitwise

  def parse(text) when is_binary(text) do
    [ip | suffix] = String.split(String.trim(text), "/", parts: 2)

    with {:ok, {a, b, c, d}} <- :inet.parse_ipv4strict_address(String.to_charlist(ip)),
         width = List.first(suffix) || "32",
         {bits, ""} when bits in 0..32 <- Integer.parse(width),
         true <- Integer.to_string(bits) == width do
      <<addr::32>> = <<a, b, c, d>>
      {:ok, {addr, bits}}
    else
      _ -> :error
    end
  end

  def covered?(text, prefixes) do
    case parse(text) do
      {:ok, {address, size}} -> Enum.any?(prefixes, &contains?(&1, address, size))
      :error -> false
    end
  end

  defp contains?(prefix, address, size) do
    case parse(prefix) do
      {:ok, {base, bits}} -> bits <= size and address >>> (32 - bits) == base >>> (32 - bits)
      :error -> false
    end
  end
end
