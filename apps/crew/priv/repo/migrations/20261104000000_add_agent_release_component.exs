defmodule Crew.Repo.Migrations.AddAgentReleaseComponent do
  use Ecto.Migration

  # A release has two tarballs per target, the agent and crew_cache
  # (§20.2: the cache updates with the agent, at the same version).
  def change do
    drop unique_index(:agent_releases, [:version, :target])

    alter table(:agent_releases) do
      add :component, :string, null: false, default: "agent"
    end

    create unique_index(:agent_releases, [:component, :version, :target])
  end
end
