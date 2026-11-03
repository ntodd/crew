defmodule Crew.Repo.Migrations.AddRunAttemptPrNumber do
  use Ecto.Migration

  # The Runs page filters by PR. Runs have one PR at most in practice;
  # this is the first one, indexed, so the filter is portable.
  def change do
    alter table(:run_attempts) do
      add :pr_number, :integer
    end

    create index(:run_attempts, [:repo_id, :pr_number])
  end
end
