defmodule Crew.Images.Upkeep do
  @moduledoc """
  Daily: fetch again any mirrored image whose files have gone, and let go
  of old releases' files past the rollback window (`Crew.Images`).
  """
  use Oban.Worker, queue: :images, max_attempts: 3, unique: [period: 3600]

  @impl true
  def perform(_job) do
    Crew.Images.check_mirrors()
    Crew.Images.evict_mirrors()
  end
end
