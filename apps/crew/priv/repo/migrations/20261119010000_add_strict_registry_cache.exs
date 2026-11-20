defmodule Crew.Repo.Migrations.AddStrictRegistryCache do
  use Ecto.Migration

  def change do
    alter table(:cache_config) do
      add :strict_registry_cache, :boolean, null: false, default: false
    end
  end
end
