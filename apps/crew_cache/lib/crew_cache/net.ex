defmodule CrewCache.Net do
  @moduledoc """
  The addresses the cache must never connect to (§15.5), and that its
  resolver strips from answers (§15.2): `blocked4` as the box firewall
  has it (§14.2), plus `site4`, this site's own addresses.

  The cache dials IPv4 only, so every IPv6 address is refused.

  A policy can carry exceptions for tests (a fake upstream on loopback).
  Only loopback can be excepted, whatever the configuration says, and
  `config/runtime.exs` never sets any.
  """

  import Bitwise

  @blocked4 ~w(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
               192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
               203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32)

  @loopback {{127, 0, 0, 0}, 8}

  @type cidr :: {:inet.ip4_address(), 0..32}
  @type policy :: %{refused: [cidr], except: [cidr]}

  @doc "The CIDRs in blocked4."
  def blocked4, do: Enum.map(@blocked4, &parse_cidr!/1)

  @doc """
  A policy refusing blocked4 and `site4` (CIDR strings), except for
  `except`, of which only the parts inside loopback count.
  """
  @spec policy([String.t()], [String.t()]) :: policy
  def policy(site4, except) do
    except =
      except
      |> Enum.flat_map(&List.wrap(ok(parse_cidr(&1))))
      |> Enum.filter(&inside?(&1, @loopback))

    %{refused: blocked4() ++ Enum.flat_map(site4, &List.wrap(ok(parse_cidr(&1)))), except: except}
  end

  @doc "The policy in force (`CrewCache.Settings` keeps it current)."
  def current, do: :persistent_term.get({__MODULE__, :policy}, policy([], []))

  @doc false
  def put_current(policy), do: :persistent_term.put({__MODULE__, :policy}, policy)

  @doc "Whether the cache must not connect to `ip` (or keep it in a DNS answer)."
  @spec refused?(:inet.ip_address(), policy) :: boolean
  def refused?({_, _, _, _} = ip, %{refused: refused, except: except}) do
    not Enum.any?(except, &member?(ip, &1)) and Enum.any?(refused, &member?(ip, &1))
  end

  def refused?(_ipv6, _policy), do: true

  @doc "Whether `ip` is in `cidr`."
  def member?({_, _, _, _} = ip, {net, bits}), do: mask(to_int(ip), bits) == to_int(net)
  def member?(_ip, _cidr), do: false

  @doc "Whether CIDR `a` lies inside CIDR `b`."
  def inside?({net, bits}, {_, outer} = b), do: bits >= outer and member?(net, b)

  @doc "Whether two CIDRs share any address."
  def overlap?({_, a} = x, {_, b} = y), do: if(a >= b, do: inside?(x, y), else: inside?(y, x))

  @doc "`a.b.c.d/n` (or a bare address, /32) as `{network, bits}`."
  @spec parse_cidr(String.t()) :: {:ok, cidr} | :error
  def parse_cidr(text) when is_binary(text) do
    with [ip | rest] when length(rest) <= 1 <- String.split(String.trim(text), "/"),
         {:ok, addr} <- :inet.parse_ipv4strict_address(String.to_charlist(ip)),
         {:ok, bits} <- bits(rest) do
      {:ok, {from_int(mask(to_int(addr), bits)), bits}}
    else
      _ -> :error
    end
  end

  def parse_cidr(_), do: :error

  def parse_cidr!(text) do
    {:ok, cidr} = parse_cidr(text)
    cidr
  end

  defp bits([]), do: {:ok, 32}

  defp bits([text]) do
    case Integer.parse(text) do
      {n, ""} when n in 0..32 -> {:ok, n}
      _ -> :error
    end
  end

  defp ok({:ok, v}), do: v
  defp ok(:error), do: nil

  @doc "The CIDR text for `{network, bits}`."
  def format({net, bits}), do: "#{:inet.ntoa(net)}/#{bits}"

  @doc """
  The networks of the interfaces that are up, without loopback, as CIDR
  strings: the uplink's connected subnets, part of site4 (§14.2).
  """
  def connected(ifaddrs) do
    for {_name, opts} <- ifaddrs,
        flags = Keyword.get(opts, :flags, []),
        :up in flags and :loopback not in flags,
        {addr, netmask} <- pairs(opts),
        uniq: true,
        do: format({from_int(mask(to_int(addr), prefix_len(netmask))), prefix_len(netmask)})
  end

  # getifaddrs lists each address followed by its netmask.
  defp pairs(opts) do
    opts
    |> Enum.chunk_while(
      nil,
      fn
        {:addr, {_, _, _, _} = a}, _ -> {:cont, a}
        {:netmask, {_, _, _, _} = m}, a when is_tuple(a) -> {:cont, {a, m}, nil}
        {:addr, _}, _ -> {:cont, nil}
        _, acc -> {:cont, acc}
      end,
      fn _ -> {:cont, nil} end
    )
  end

  defp prefix_len(netmask), do: netmask |> to_int() |> Integer.digits(2) |> Enum.count(&(&1 == 1))

  defp mask(_n, 0), do: 0
  defp mask(n, bits), do: n &&& bsl(0xFFFFFFFF, 32 - bits) &&& 0xFFFFFFFF

  @doc false
  def to_int({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  @doc false
  def from_int(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
end
