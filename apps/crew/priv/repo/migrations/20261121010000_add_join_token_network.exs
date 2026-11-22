defmodule Crew.Repo.Migrations.AddJoinTokenNetwork do
  use Ecto.Migration

  def change do
    alter table(:join_tokens) do
      add :uplink, :string
      add :extra_blocked, :text
    end
  end
end
