defmodule Crew.Repo.Migrations.CreateUsageTables do
  use Ecto.Migration

  # Daily usage totals (§16.6), kept forever (§9.4): job and VM rows go
  # after 90 days, so the minutes they add up to are rolled up into these
  # first. Seconds and MiB-seconds are bigints: a 32 GiB VM held for a
  # day is 2.8 billion MiB-seconds.
  def change do
    create table(:usage_days, primary_key: false) do
      add :day, :date, null: false
      add :box_id, references(:boxes, on_delete: :delete_all)
      add :repo_id, references(:repos, on_delete: :delete_all), null: false
      add :vcpus, :integer
      add :memory_mib, :integer
      add :vm_count, :integer, null: false, default: 0
      add :unused_count, :integer, null: false, default: 0
      add :boot_s, :bigint, null: false, default: 0
      add :idle_s, :bigint, null: false, default: 0
      add :busy_s, :bigint, null: false, default: 0
      add :teardown_s, :bigint, null: false, default: 0
      add :vcpu_s, :bigint, null: false, default: 0
      add :mem_mib_s, :bigint, null: false, default: 0
      add :job_count, :integer, null: false, default: 0
      add :success_count, :integer, null: false, default: 0
      add :failure_count, :integer, null: false, default: 0
      add :job_s, :bigint, null: false, default: 0
      add :job_billable_min, :bigint, null: false, default: 0
    end

    create index(:usage_days, [:day])
    create index(:usage_days, [:repo_id, :day])
    create index(:usage_days, [:box_id, :day])

    create table(:usage_box_days, primary_key: false) do
      add :day, :date, null: false
      add :box_id, references(:boxes, on_delete: :delete_all), null: false
      add :online_s, :bigint
      add :allocatable_vcpus, :float
      add :allocatable_memory_mib, :bigint
    end

    create unique_index(:usage_box_days, [:box_id, :day])

    # A day rolled up, with or without rows.
    create table(:usage_rollups, primary_key: false) do
      add :day, :date, primary_key: true
      add :computed_at, :utc_datetime_usec, null: false
    end
  end
end
