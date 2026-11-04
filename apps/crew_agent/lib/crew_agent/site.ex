defmodule CrewAgent.Site do
  @moduledoc """
  `site4` (§14.2): this site's own addresses, which a guest mustn't reach
  even where they aren't private (a hairpin through the router's public
  address into a forwarded port, or a publicly numbered LAN):

  - the box's connected IPv4 subnets;
  - the site's public egress address, from an echo service
    (`CREW_EGRESS_ECHO_URL`) at boot and every 10 minutes (spike S12);
  - the admin's `CREW_EXTRA_BLOCKED`.

  A VM gets the set as it is when it starts.
  """
  use GenServer

  require Logger

  alias CrewAgent.Config

  @every_ms 10 * 60_000
  @crew_ranges ["10.199.0.0/16"]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "site4 for a VM starting now."
  def current(config \\ Config.get()) do
    {:ok, ifaddrs} = :inet.getifaddrs()
    site4(config, connected(ifaddrs, config.vm_net), egress())
  end

  @doc "The last egress address the echo service gave, if any."
  def egress, do: :persistent_term.get({__MODULE__, :egress}, nil)

  @doc false
  def site4(config, connected, egress) do
    Enum.uniq(connected ++ if(egress, do: ["#{egress}/32"], else: []) ++ config.extra_blocked)
  end

  @doc "The networks of the interfaces that are up, without loopback or Crew's own ranges."
  def connected(ifaddrs, vm_net) do
    crew = Enum.map([vm_net | @crew_ranges], &parse_cidr/1)

    for {_name, opts} <- ifaddrs,
        :up in Keyword.get(opts, :flags, []),
        :loopback not in Keyword.get(opts, :flags, []),
        {addr, mask} <- pairs(opts),
        not Enum.any?(crew, &within?(addr, &1)),
        uniq: true,
        do: cidr(addr, mask)
  end

  # getifaddrs lists each address followed by its netmask.
  defp pairs(opts) do
    opts
    |> Enum.chunk_while(
      nil,
      fn
        {:addr, {_, _, _, _} = a}, _ -> {:cont, a}
        {:netmask, {_, _, _, _} = m}, a when is_tuple(a) -> {:cont, {a, m}, nil}
        _, acc -> {:cont, acc}
      end,
      fn _ -> {:cont, nil} end
    )
  end

  defp cidr(addr, mask) do
    bits = mask |> Tuple.to_list() |> Enum.map(&popcount/1) |> Enum.sum()
    "#{:inet.ntoa(network(addr, bits))}/#{bits}"
  end

  defp popcount(byte), do: for(<<(b::1 <- <<byte>>)>>, reduce: 0, do: (acc -> acc + b))

  defp network(addr, bits) do
    <<n::32>> = ip_bin(addr)
    masked = Bitwise.band(n, Bitwise.bsl(0xFFFFFFFF, 32 - bits) |> Bitwise.band(0xFFFFFFFF))
    <<a, b, c, d>> = <<masked::32>>
    {a, b, c, d}
  end

  defp ip_bin({a, b, c, d}), do: <<a, b, c, d>>

  defp parse_cidr(text) do
    [ip, bits] = String.split(text, "/")
    {:ok, addr} = :inet.parse_ipv4strict_address(String.to_charlist(ip))
    {network(addr, String.to_integer(bits)), String.to_integer(bits)}
  end

  defp within?(addr, {net, bits}), do: network(addr, bits) == net

  @doc false
  def parse_egress(body) do
    text = String.trim(body)

    case :inet.parse_ipv4strict_address(String.to_charlist(text)) do
      {:ok, _} -> text
      _ -> nil
    end
  end

  # -- the egress address --------------------------------------------------------

  @impl true
  def init(_) do
    send(self(), :check)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @every_ms)

    with url when is_binary(url) <- Application.get_env(:crew_agent, :egress_echo_url),
         {:ok, %{status: 200, body: body}} <-
           Req.get(url, retry: false, receive_timeout: 10_000, redirect: false),
         ip when is_binary(ip) <- parse_egress(to_string(body)) do
      :persistent_term.put({__MODULE__, :egress}, ip)
    else
      nil ->
        :ok

      other ->
        Logger.warning(
          "couldn't learn the site's egress address: #{inspect(other) |> String.slice(0, 200)}"
        )
    end

    {:noreply, state}
  end
end
