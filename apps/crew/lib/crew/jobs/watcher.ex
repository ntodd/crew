defmodule Crew.Jobs.Watcher do
  @moduledoc """
  Re-parses queued jobs when what classifies them changes (§7.4): a
  repo's settings, the sizes or the aliases.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Crew.Sizes.subscribe()
    Crew.Repos.subscribe_settings()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sizes_changed, state) do
    Crew.Jobs.reclassify_open()
    {:noreply, state}
  end

  def handle_info({:repo_settings_changed, repo_id}, state) do
    Crew.Jobs.reclassify_open(repo_id: repo_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
