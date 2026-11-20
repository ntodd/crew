defmodule Crew.Repo.Migrations.AddJoinTokenDisks do
  use Ecto.Migration

  # A linux-metal box's disks (§12.2): its OS disk and whether /srv/crew
  # is partition 10 of it ("one") or a disk of its own ("separate"). Null
  # on tokens from before, which had a data disk and count as separate.
  def change do
    alter table(:join_tokens) do
      add :os_disk, :string
      add :disk_layout, :string
    end
  end
end
