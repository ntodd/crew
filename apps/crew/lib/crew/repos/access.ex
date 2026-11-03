defmodule Crew.Repos.Access do
  @moduledoc "Whether a member can read (and push to) a repo, from their GitHub token (§18.3)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "user_repo_access" do
    belongs_to :user, Crew.Accounts.User, primary_key: true
    belongs_to :repo, Crew.Repos.Repo, primary_key: true
    field :can_push, :boolean, default: false
    field :checked_at, :utc_datetime_usec
  end
end
