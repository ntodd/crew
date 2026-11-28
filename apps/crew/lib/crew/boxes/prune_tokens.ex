defmodule Crew.Boxes.PruneTokens do
  @moduledoc "Hourly: join tokens past their hour (`Crew.Boxes.prune_join_tokens/1`)."
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 1800]

  @impl true
  def perform(_job), do: Crew.Boxes.prune_join_tokens()
end
