defmodule Crew.Repo.Migrations.IndexOperationsHistory do
  use Ecto.Migration

  def change do
    create index(:operations, [:box_id, :inserted_at])
    create index(:operations, [:finished_at], where: "finished_at IS NOT NULL")
  end
end
