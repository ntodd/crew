defmodule Crew.Agents.UpdateSweep do
  @moduledoc """
  Every minute: settles agent updates under way, overdue ones included,
  and sends what's due to the boxes online (`Crew.Agents.Updates.sweep/0`,
  Foreman's housekeeping and dispatch crons).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 50]

  @impl true
  def perform(_job), do: Crew.Agents.Updates.sweep()
end
