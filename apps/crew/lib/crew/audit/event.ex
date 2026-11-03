defmodule Crew.Audit.Event do
  @moduledoc false
  use Crew.Schema

  schema "audit_events" do
    belongs_to :actor, Crew.Accounts.User
    field :actor_login, :string
    field :action, :string
    field :subject_type, :string
    field :subject_id, :string
    field :metadata, :map
    timestamps(updated_at: false)
  end
end
