defmodule Crew.Repo.Migrations.AddBoxRebootTarget do
  use Ecto.Migration

  # What a pending reboot is of (§12.1): the box itself ("box", through
  # box.restart) or a mac-vz box's cache VM ("cache_vm").
  def change do
    alter table(:boxes) do
      add :reboot_target, :string
    end
  end
end
