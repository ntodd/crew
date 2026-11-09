defmodule Crew.Repo.Migrations.AddSpareTier do
  use Ecto.Migration

  # Spare jobs (§7.2) run only on capacity regular jobs aren't using. A
  # job's tier comes from its labels; a VM's is the tier it was placed
  # for and never changes, so a spare VM that takes a regular job still
  # counts toward its box's spare share.
  def change do
    alter table(:jobs) do
      add :spare, :boolean, null: false, default: false
    end

    alter table(:vms) do
      add :spare, :boolean, null: false, default: false
    end
  end
end
