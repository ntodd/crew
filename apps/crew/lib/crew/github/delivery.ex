defmodule Crew.GitHub.Delivery do
  @moduledoc "A webhook delivery Crew has received (§6.2). There's no payload column."
  use Ecto.Schema

  @primary_key {:github_delivery_id, :string, autogenerate: false}
  schema "webhook_deliveries" do
    field :event, :string
    field :action, :string
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :error, :string
  end
end
