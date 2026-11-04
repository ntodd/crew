defmodule Crew.Cache do
  @moduledoc """
  A small in-memory cache for values every viewer of a page would compute
  alike, such as the dashboard's and queue's charts (§17.3): one read per
  interval, not one per open tab. Values live in a public ETS table this
  process owns; a stale value is recomputed by whichever caller finds it.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The value under `key` if computed within `ttl_ms`, else `fun.()`, stored."
  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, at, value}] when now - at < ttl_ms ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, now, value})
        value
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
