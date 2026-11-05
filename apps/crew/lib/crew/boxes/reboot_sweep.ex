defmodule Crew.Boxes.RebootSweep do
  @moduledoc """
  Every minute: each pending reboot's command goes again once its box has
  no VM left (`Crew.Boxes.Reboots.advance/1`). The events that send it
  (a VM's end, an inventory, a rejoin) can all pass while the command
  doesn't get through; a resent one after the reboot does nothing.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 50]

  import Ecto.Query

  alias Crew.Boxes.{Box, Reboots}

  @impl true
  def perform(_job) do
    from(b in Box,
      where: not is_nil(b.reboot_requested_at) and is_nil(b.revoked_at),
      select: b.id
    )
    |> Crew.Repo.all()
    |> Enum.each(&Reboots.advance/1)
  end
end
