defmodule Crew.Schema do
  @moduledoc false
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      # Row ids are UUIDv7 (§22): time-ordered, so keyset pagination by id
      # follows creation order.
      @primary_key {:id, Crew.UUIDv7, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
