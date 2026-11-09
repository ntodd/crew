defmodule Crew.Repo.Migrations.AddRunAttemptUpdatedIndex do
  use Ecto.Migration

  # Job retention (§9.4) looks for run attempts that haven't changed for
  # CREW_JOB_RETENTION_DAYS every hour, and their jobs on
  # jobs(run_attempt_id); without this it scans every attempt kept.
  def change do
    create index(:run_attempts, [:updated_at])
  end
end
