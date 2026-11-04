defmodule Crew.Repo.Migrations.AddHistoryIndexes do
  use Ecto.Migration

  # The dashboard's and queue's charts read recent history by time
  # (§17.3); without these they scan every job and VM ever kept.
  def change do
    create index(:jobs, [:started_at])
    create index(:jobs, [:classification, :gh_state, :completed_at])
    create index(:vms, [:requested_at])
  end
end
