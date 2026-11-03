defmodule Crew.Activity.Event do
  @moduledoc "One entry in the activity feed."
  use Crew.Schema

  schema "activity_events" do
    field :kind, :string
    field :box_id, :binary_id
    field :repo_id, :binary_id
    field :message, :string
    field :metadata, :map, default: %{}
    timestamps(updated_at: false)
  end
end
