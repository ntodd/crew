defmodule Crew.Repo.Migrations.AddVMMetricReadings do
  use Ecto.Migration

  # What newer guests report (§16.5): the highest used memory since the
  # last sample, the kernel's OOM kill count since boot, and the share of
  # the interval some (or every) task stalled on CPU or memory. Null for a
  # sample from an older guest or agent, which can't say.
  def change do
    alter table(:vm_metrics) do
      add :mem_peak_mib, :integer
      add :oom_kills, :integer
      add :cpu_pressure_pct, :float
      add :mem_pressure_pct, :float
      add :mem_full_pressure_pct, :float
    end
  end
end
