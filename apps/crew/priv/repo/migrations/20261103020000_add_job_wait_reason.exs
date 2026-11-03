defmodule Crew.Repo.Migrations.AddJobWaitReason do
  use Ecto.Migration

  # Why a job that is demand isn't placed yet ("no box with 16 GiB free"),
  # as opposed to `blocked_reason`, which takes it out of demand (§8.2).
  def change do
    alter table(:jobs) do
      add :wait_reason, :text
    end

    alter table(:vms) do
      add :stop_sent_at, :utc_datetime_usec
      add :runner_delete_since, :utc_datetime_usec
    end
  end
end
