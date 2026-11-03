defmodule Crew.Operations.Operation do
  @moduledoc "A command sent to a box's agent, and its result. `args` never hold the JIT config."
  use Crew.Schema

  schema "operations" do
    belongs_to :box, Crew.Boxes.Box
    field :vm_id, :binary_id
    belongs_to :user, Crew.Accounts.User
    field :command, :string
    field :args, :map
    field :status, :string, default: "queued"
    field :error_code, :string
    field :error, :string
    field :result, :map
    field :dispatched_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps()
  end
end
