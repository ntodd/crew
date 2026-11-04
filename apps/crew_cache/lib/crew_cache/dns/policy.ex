defmodule CrewCache.DNS.Policy do
  @moduledoc """
  What the resolver refuses and strips (§15.2):

  - **Refused:** `ANY`, `AXFR` and `IXFR`; names under (or equal to)
    `.local`, `.lan`, `.internal`, `.home.arpa`, `.ts.net` and
    `.localhost`; reverse lookups whose range overlaps blocked4 or site4
    (`10.in-addr.arpa` too), and IPv6 reverse lookups in loopback,
    link-local, ULA and IPv4-mapped space. A malformed reverse name is
    refused.
  - **Stripped from every section:** A records in blocked4 or site4;
    AAAA records that are loopback, unspecified, link-local, ULA, or an
    IPv4-mapped or NAT64 form of a refused IPv4 address; and SVCB and
    HTTPS records, whose address hints would otherwise carry what the A
    records can't (clients fall back to A and AAAA).
  """

  import Bitwise

  alias CrewCache.Net

  @refused_types [:any, :axfr, :ixfr, 255, 252, 251]
  @private_suffixes ~w(local lan internal home.arpa ts.net localhost)
  @hint_types [:svcb, :https, 64, 65]

  # IPv6 reverse ranges as nibble prefixes: fc00::/7, fe80::/10, and the
  # first 80 bits zero (::, ::1, ::ffff:a.b.c.d).
  @v6_refused [
    [[0xF], [0xC, 0xD]],
    [[0xF], [0xE], [0x8, 0x9, 0xA, 0xB]],
    List.duplicate([0], 20)
  ]

  @doc "Whether to answer REFUSED to `name` (lowercase, no trailing dot) of `type`."
  def refuse?(name, type, policy) do
    type in @refused_types or private?(name) or reverse_refused?(name, policy)
  end

  defp private?(name) do
    Enum.any?(@private_suffixes, &(name == &1 or String.ends_with?(name, "." <> &1)))
  end

  defp reverse_refused?(name, policy) do
    cond do
      name == "in-addr.arpa" or String.ends_with?(name, ".in-addr.arpa") ->
        v4_reverse_refused?(name |> String.replace_suffix("in-addr.arpa", "") |> labels(), policy)

      name == "ip6.arpa" or String.ends_with?(name, ".ip6.arpa") ->
        v6_reverse_refused?(name |> String.replace_suffix("ip6.arpa", "") |> labels())

      true ->
        false
    end
  end

  defp labels(prefix), do: prefix |> String.split(".", trim: true) |> Enum.reverse()

  defp v4_reverse_refused?(labels, _policy) when length(labels) > 4, do: true

  defp v4_reverse_refused?(labels, policy) do
    case octets(labels) do
      :error ->
        true

      octets ->
        net = octets ++ List.duplicate(0, 4 - length(octets))
        cidr = {List.to_tuple(net), 8 * length(octets)}
        Enum.any?(policy.refused, &Net.overlap?(cidr, &1))
    end
  end

  defp octets(labels) do
    Enum.reduce_while(labels, [], fn label, acc ->
      case Integer.parse(label) do
        {n, ""} when n in 0..255 -> {:cont, acc ++ [n]}
        _ -> {:halt, :error}
      end
    end)
  end

  defp v6_reverse_refused?(labels) when length(labels) > 32, do: true

  defp v6_reverse_refused?(labels) do
    case nibbles(labels) do
      :error -> true
      nibbles -> Enum.any?(@v6_refused, &prefix_overlap?(nibbles, &1))
    end
  end

  defp nibbles(labels) do
    Enum.reduce_while(labels, [], fn label, acc ->
      case Integer.parse(label, 16) do
        {n, ""} when n in 0..15 and byte_size(label) == 1 -> {:cont, acc ++ [n]}
        _ -> {:halt, :error}
      end
    end)
  end

  defp prefix_overlap?(nibbles, range) do
    nibbles |> Enum.zip(range) |> Enum.all?(fn {n, allowed} -> n in allowed end)
  end

  @doc "Records with what mustn't reach a guest taken out."
  def strip(records, policy), do: Enum.reject(records, &strip?(&1, policy))

  defp strip?(rr, policy) do
    case record(rr) do
      {:a, ip} -> Net.refused?(ip, policy)
      {:aaaa, ip} -> refused6?(ip, policy)
      {type, _} -> type in @hint_types
      :other -> false
    end
  end

  defp record(rr) do
    {:inet_dns.rr(rr, :type), :inet_dns.rr(rr, :data)}
  rescue
    _ -> :other
  end

  defp refused6?({0, 0, 0, 0, 0, 0, 0, n}, _policy) when n in [0, 1], do: true
  defp refused6?({a, _, _, _, _, _, _, _}, _policy) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp refused6?({a, _, _, _, _, _, _, _}, _policy) when (a &&& 0xFE00) == 0xFC00, do: true
  defp refused6?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}, policy), do: Net.refused?(v4(hi, lo), policy)
  defp refused6?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}, policy), do: Net.refused?(v4(hi, lo), policy)
  defp refused6?(_ip, _policy), do: false

  defp v4(hi, lo), do: {hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}
end
