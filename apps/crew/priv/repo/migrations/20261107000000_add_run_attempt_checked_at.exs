defmodule Crew.Repo.Migrations.AddRunAttemptCheckedAt do
  use Ecto.Migration

  # The reconciler re-checks open run attempts whose jobs are all done
  # (§8.8), every 5 minutes at most. It reads only what isn't finished,
  # every 15 s, and neither table is pruned: partial indexes keep that
  # off the finished rows.
  def change do
    alter table(:run_attempts) do
      add :checked_at, :utc_datetime_usec
    end

    create index(:run_attempts, [:checked_at],
             where: "status != 'completed'",
             name: :run_attempts_open_index
           )

    create index(:jobs, [:last_event_at],
             where: "gh_state != 'completed'",
             name: :jobs_open_index
           )
  end
end
