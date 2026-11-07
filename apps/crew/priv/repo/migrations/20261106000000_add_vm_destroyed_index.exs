defmodule Crew.Repo.Migrations.AddVmDestroyedIndex do
  use Ecto.Migration

  # The Boxes page reads what VMs held over a range (§17.3): the ones
  # destroyed since its start, however long ago they were requested.
  def change do
    create index(:vms, [:destroyed_at])
  end
end
