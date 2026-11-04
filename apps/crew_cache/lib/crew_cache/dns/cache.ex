defmodule CrewCache.DNS.Cache do
  @moduledoc """
  The resolver's memory, in ETS:

  - answers by `(name, type, class)`, kept for their smallest TTL,
    capped at 300 s, at most 5000 at once (a full cache stops adding
    until the next sweep, every 5 s, frees room);
  - a token bucket per client address: 100 queries a second, with
    bursts up to 100.
  """
  use GenServer

  @answers :crew_dns_answers
  @rate :crew_dns_rate
  @max_entries 5000
  @max_ttl 300
  @rate_per_s 100

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A cached answer with its TTLs aged, or `:miss`."
  def get(key) do
    now = now_ms()

    case :ets.lookup(@answers, key) do
      [{^key, answer, stored, expires}] when expires > now ->
        {:ok, age(answer, div(now - stored, 1000))}

      _ ->
        :miss
    end
  end

  def put(_key, _answer, ttl) when ttl <= 0, do: :ok

  def put(key, answer, ttl) do
    if :ets.info(@answers, :size) < @max_entries do
      now = now_ms()
      :ets.insert(@answers, {key, answer, now, now + min(ttl, @max_ttl) * 1000})
    end

    :ok
  end

  def max_ttl, do: @max_ttl

  defp age(answer, 0), do: answer

  defp age(answer, seconds) do
    Map.new(answer, fn
      {section, rrs} when section in [:an, :ns, :ar] ->
        {section,
         Enum.map(rrs, &:inet_dns.make_rr(&1, ttl: max(:inet_dns.rr(&1, :ttl) - seconds, 0)))}

      other ->
        other
    end)
  end

  @doc "Whether `ip` may ask another query now."
  def allow?(ip) do
    now = now_ms()

    {tokens, last} =
      case :ets.lookup(@rate, ip) do
        [{^ip, tokens, last}] -> {tokens, last}
        [] -> {@rate_per_s * 1.0, now}
      end

    tokens = min(@rate_per_s * 1.0, tokens + (now - last) * @rate_per_s / 1000)

    if tokens >= 1 do
      :ets.insert(@rate, {ip, tokens - 1, now})
      true
    else
      :ets.insert(@rate, {ip, tokens, now})
      false
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_) do
    :ets.new(@answers, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@rate, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, 5000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@answers, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    # A bucket untouched for 2 s is full again: forget it.
    :ets.select_delete(@rate, [{{:_, :_, :"$1"}, [{:<, :"$1", now - 2000}], [true]}])
    Process.send_after(self(), :sweep, 5000)
    {:noreply, state}
  end
end
