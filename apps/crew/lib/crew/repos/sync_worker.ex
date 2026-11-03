defmodule Crew.Repos.SyncWorker do
  @moduledoc "Syncs installations and repos on a timer, as well as on their webhooks."
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 300]

  @impl true
  def perform(_job) do
    if Crew.GitHub.configured?() do
      case Crew.Repos.sync_all() do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end
end
