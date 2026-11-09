defmodule Crew.Repo.Migrations.AddBoxSparePct do
  use Ecto.Migration

  # The share of a box spare jobs may use (§8.3): a percentage of its
  # allocatable memory, vCPUs and max_vms. Null means 50.
  def change do
    alter table(:boxes) do
      add :spare_pct, :integer
    end
  end
end
