defmodule Crew.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  # Workflows Crew starts on a cron with workflow_dispatch (§7.6). A
  # repo's schedules go with it. `last_due_at` is the schedule's clock:
  # the latest cron minute accounted for, whether or not the dispatch
  # succeeded.
  def change do
    create table(:schedules) do
      add :repo_id, references(:repos, on_delete: :delete_all), null: false
      add :workflow, :string, null: false
      add :ref, :string, null: false
      add :cron, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :last_due_at, :utc_datetime_usec, null: false
      add :last_dispatched_at, :utc_datetime_usec
      add :last_error, :text
      timestamps()
    end

    create unique_index(:schedules, [:repo_id, :workflow, :ref, :cron])
  end
end
