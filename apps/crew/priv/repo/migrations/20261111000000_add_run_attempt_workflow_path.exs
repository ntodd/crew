defmodule Crew.Repo.Migrations.AddRunAttemptWorkflowPath do
  use Ecto.Migration

  # The run's workflow file as GitHub gives it (`path`), so a right-sizing
  # hint can say which file to edit (§7.5). Null for attempts from before.
  # Text: a file name may be longer than Postgres's varchar(255).
  def change do
    alter table(:run_attempts) do
      add :workflow_path, :text
    end
  end
end
