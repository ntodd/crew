defmodule Crew.Agents.NonceCache do
  @moduledoc """
  Remembers the nonces of recent agent connects, for twice the allowed
  clock skew, so a captured connect header can't be replayed.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc ":ok the first time a nonce is seen, :replay after that."
  def check(nonce, now \\ System.system_time(:second)) do
    expires = now + 2 * CrewProtocol.Auth.max_skew()
    if :ets.insert_new(@table, {nonce, expires}), do: :ok, else: :replay
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :prune, 30_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :prune, 30_000)
    {:noreply, state}
  end
end
