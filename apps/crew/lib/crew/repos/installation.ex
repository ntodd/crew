defmodule Crew.Repos.Installation do
  @moduledoc "An installation of the App on an account (§22)."
  use Crew.Schema

  schema "installations" do
    field :github_id, :integer
    field :account_login, :string
    field :account_type, :string, default: "User"
    field :account_id, :integer
    field :permissions, :map, default: %{}
    field :suspended_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :synced_at, :utc_datetime_usec
    has_many :repos, Crew.Repos.Repo
    timestamps()
  end
end
