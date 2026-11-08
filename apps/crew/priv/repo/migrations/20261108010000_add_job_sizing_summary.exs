defmodule Crew.Repo.Migrations.AddJobSizingSummary do
  use Ecto.Migration

  # What right-sizing hints need from a job once its VM's samples are
  # pruned (§7.5): the shape it ran on, its average stall pressure, for
  # each smaller vCPU count the core-seconds of demand above it, and how
  # much of the job the samples cover (null until the VM is gone and the
  # summary is final).
  # Hints look a job's history up by (repo, workflow, name), newest
  # first, as "usually X" does; jobs aren't pruned, so that needs an
  # index.
  def change do
    alter table(:jobs) do
      add :vcpus, :integer
      add :memory_mib, :integer
      add :cpu_pressure_pct, :float
      add :mem_pressure_pct, :float
      add :mem_full_pressure_pct, :float
      add :cpu_excess, {:array, :float}
      add :coverage, :float
    end

    create index(:jobs, [:repo_id, :workflow_name, :name, :completed_at])
  end
end
