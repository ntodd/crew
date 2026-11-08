defmodule Crew.Usage.RolledDay do
  @moduledoc "A UTC day `Crew.Usage.Rollup` has stored, even one with no rows (§16.6, §22)."
  use Ecto.Schema

  @primary_key {:day, :date, autogenerate: false}
  schema "usage_rollups" do
    field :computed_at, :utc_datetime_usec
  end
end
