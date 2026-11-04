defmodule Crew.Repo.Migrations.AddCacheBoxState do
  use Ecto.Migration

  # §15.4, §17.3: the CA generation each box's cache was last sent (so a
  # box offline for a rotation rotates when it's back), its top images
  # from the last cache.stats, and evictions alongside the counters.
  def change do
    alter table(:boxes) do
      add :cache_ca_generation, :integer, null: false, default: 1
      add :cache_top, {:array, :map}, null: false, default: []
    end

    alter table(:cache_stats) do
      add :evictions, :bigint, null: false, default: 0
    end
  end
end
