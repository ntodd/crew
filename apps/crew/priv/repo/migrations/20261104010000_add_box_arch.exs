defmodule Crew.Repo.Migrations.AddBoxArch do
  use Ecto.Migration

  # The agent's own architecture (x64 or arm64), from its join: with
  # `os`, the release target an update is for (§20.2). Not the guests'
  # (guest_arch), though on every driver Crew has they're the same.
  def change do
    alter table(:boxes) do
      add :arch, :string
    end
  end
end
