defmodule Crew.Repo.Migrations.AddVmLogBytes do
  use Ecto.Migration

  # How much of a VM's live.ndjson is committed with its row: a restart
  # cuts the file back to it, so a write whose row update failed is
  # written again by the replay instead of twice.
  def change do
    alter table(:vms) do
      add :log_bytes, :bigint, null: false, default: 0
    end
  end
end
