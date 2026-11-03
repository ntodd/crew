defmodule Crew.Images.BoxImage do
  @moduledoc "An image's state on one box (§13.1)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "box_images" do
    field :box_id, :binary_id, primary_key: true
    field :image_id, :binary_id, primary_key: true
    field :state, :string
    field :progress, :integer, default: 0
    field :error, :string
    field :attempts, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
