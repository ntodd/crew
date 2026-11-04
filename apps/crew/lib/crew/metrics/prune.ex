defmodule Crew.Metrics.Prune do
  @moduledoc "Hourly: drops box, VM and cache samples past their 7 days (§9.4, Foreman's `PruneMetrics`)."
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 1800]

  @impl true
  def perform(_job), do: Crew.Metrics.prune()
end
