defmodule Crew.Repo.Migrations.AddBoxImageRefusedAt do
  use Ecto.Migration

  # When the box's last image_not_ready refusal struck it (§8.6): one
  # strike per batch of placements, whatever the box reports after.
  def change do
    alter table(:boxes) do
      add :image_refused_at, :utc_datetime_usec
    end
  end
end
