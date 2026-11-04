defmodule CrewCache.Upstream.Memo do
  @moduledoc """
  Short-lived memory for upstream requests, in ETS:

  - anonymous tokens per `(host, repository)`, until they expire;
  - the tag micro-cache (§15.3): `(host, repo, tag, normalised Accept)`
    to what the upstream's HEAD said, for `tag_ttl_ms`;
  - flags with a lifetime (digests the parent is skipped for).

  Expired entries are swept every minute; each table holds at most
  #{10_000} entries (a full table stops remembering until the sweep).
  """
  use GenServer

  @tokens :crew_cache_tokens
  @tags :crew_cache_tags
  @flags :crew_cache_flags
  @max 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def token(key), do: get(@tokens, key)
  def put_token(key, token, ttl_ms), do: put(@tokens, key, token, ttl_ms)

  def tag(key), do: get(@tags, key)
  def put_tag(key, value, ttl_ms), do: put(@tags, key, value, ttl_ms)

  def flag(key, ttl_ms), do: put(@flags, key, true, ttl_ms)
  def flagged?(key), do: get(@flags, key) == {:ok, true}

  defp get(table, key) do
    now = now()

    case :ets.lookup(table, key) do
      [{^key, value, expires}] when expires > now -> {:ok, value}
      _ -> :error
    end
  end

  defp put(_table, _key, _value, ttl) when ttl <= 0, do: :ok

  defp put(table, key, value, ttl_ms) do
    if :ets.info(table, :size) < @max, do: :ets.insert(table, {key, value, now() + ttl_ms})
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_) do
    for t <- [@tokens, @tags, @flags],
        do: :ets.new(t, [:named_table, :public, :set, read_concurrency: true])

    Process.send_after(self(), :sweep, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()

    for t <- [@tokens, @tags, @flags],
        do: :ets.select_delete(t, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state}
  end
end
