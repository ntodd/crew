defmodule Crew.GitHub.InstallationTokens do
  @moduledoc """
  Installation access tokens, cached in ETS. GitHub issues them for an
  hour; one with under five minutes left is replaced. Fetches for an
  installation are serialized, so a burst of callers makes one request.
  """
  use GenServer

  alias Crew.GitHub.Client

  @table __MODULE__
  @margin_s 300

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A current token for the installation."
  def get(installation_id) do
    case lookup(installation_id) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        :global.trans({{__MODULE__, installation_id}, self()}, fn -> fetch(installation_id) end)
    end
  end

  # Another caller may have fetched it while this one waited for the lock.
  defp fetch(id) do
    with :miss <- lookup(id),
         {:ok, %{token: token, expires_at: expires_at}} <-
           Client.create_installation_token(Crew.GitHub.app(), id) do
      :ets.insert(@table, {id, token, expires_at})
      {:ok, token}
    end
  end

  @doc "Drops a token GitHub refused."
  def invalidate(installation_id), do: :ets.delete(@table, installation_id) && :ok

  @doc false
  def clear, do: :ets.delete_all_objects(@table) && :ok

  defp lookup(id) do
    now = System.os_time(:second)

    case :ets.lookup(@table, id) do
      [{^id, token, expires_at}] when expires_at - now > @margin_s -> {:ok, token}
      _ -> :miss
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end
