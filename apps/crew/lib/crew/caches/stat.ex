defmodule Crew.Caches.Stat do
  @moduledoc """
  A box cache's counters for one host over one `cache.stats` interval
  (§15.8): what changed since the previous report, so rows sum. The
  box-wide counters (evictions, digest mismatches) are on a `*` row.
  """
  use Ecto.Schema

  @primary_key false
  schema "cache_stats" do
    field :box_id, :binary_id
    field :t, :integer
    field :host, :string
    field :hits, :integer, default: 0
    field :misses, :integer, default: 0
    field :bytes_served, :integer, default: 0
    field :bytes_stored, :integer, default: 0
    field :mismatches, :integer, default: 0
    field :evictions, :integer, default: 0
  end
end
