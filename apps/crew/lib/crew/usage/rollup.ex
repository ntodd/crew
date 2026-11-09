defmodule Crew.Usage.Rollup do
  @moduledoc """
  Hourly: stores closed UTC days' usage (§16.6, §9.3). It recomputes the
  last 2, then fills in at most 31 days not yet rolled up, oldest first,
  so a fresh deploy's history arrives over a few runs. It shares
  `:maintenance` with the prunes, so a run stays short.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 1800]

  @impl true
  def perform(_job), do: Crew.Usage.roll_up()
end
