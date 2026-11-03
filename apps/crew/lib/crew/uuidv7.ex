defmodule Crew.UUIDv7 do
  @moduledoc """
  Row ids (§22): UUIDv7, so ids sort by creation time and keyset
  pagination by id follows it. Stored as `Ecto.UUID` stores them (uuid
  on Postgres, text on SQLite). Its type is `:uuid` rather than
  `:binary_id` so Ecto calls `autogenerate/0` here instead of leaving
  the id to the adapter.
  """
  use Ecto.Type

  def type, do: :uuid

  defdelegate cast(value), to: Ecto.UUID
  defdelegate dump(value), to: Ecto.UUID
  defdelegate load(value), to: Ecto.UUID

  def autogenerate, do: CrewProtocol.uuid7()
end
