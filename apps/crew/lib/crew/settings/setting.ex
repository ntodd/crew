defmodule Crew.Settings.Setting do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "settings" do
    field :value, Crew.Encrypted.Map, redact: true
    timestamps()
  end
end
