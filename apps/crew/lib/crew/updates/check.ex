defmodule Crew.Updates.Check do
  @moduledoc """
  Looks for a newer Crew release (`Crew.Updates.check/0`), daily, and at
  boot when there's been no check yet. Off with CREW_UPDATE_CHECK=false.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 3600]

  @impl true
  def perform(_job) do
    if Crew.Updates.enabled?() do
      case Crew.Updates.check() do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
