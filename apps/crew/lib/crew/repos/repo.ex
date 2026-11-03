defmodule Crew.Repos.Repo do
  @moduledoc "A repo the App is installed on, and its Crew settings (§7.4)."
  use Crew.Schema

  schema "repos" do
    belongs_to :installation, Crew.Repos.Installation
    field :github_id, :integer
    field :full_name, :string
    field :private, :boolean, default: true
    field :default_branch, :string, default: "main"
    field :enabled, :boolean, default: true
    field :allowed_sizes, {:array, :string}
    field :allowed_boxes, {:array, :binary_id}
    field :max_concurrent, :integer
    field :fork_prs, :string, default: "refuse"
    field :priority, :integer, default: 0
    field :fork_approval_policy, :string
    field :last_activity_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    timestamps()
  end

  def github_changeset(repo, attrs) do
    repo
    |> cast(attrs, [
      :installation_id,
      :github_id,
      :full_name,
      :private,
      :default_branch,
      :archived_at
    ])
    |> validate_required([:installation_id, :github_id, :full_name])
    |> unique_constraint(:github_id)
  end

  def settings_changeset(repo, attrs, size_names) do
    repo
    |> cast(attrs, [
      :enabled,
      :allowed_sizes,
      :allowed_boxes,
      :max_concurrent,
      :fork_prs,
      :priority
    ])
    |> blank_lists_to_nil()
    |> validate_inclusion(:fork_prs, ~w(refuse allow))
    |> validate_number(:max_concurrent, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:priority, greater_than_or_equal_to: -100, less_than_or_equal_to: 100)
    |> validate_subset(:allowed_sizes, size_names, message: "has a size that doesn't exist")
  end

  # An empty selection means "all", which is stored as nil.
  defp blank_lists_to_nil(changeset) do
    Enum.reduce([:allowed_sizes, :allowed_boxes], changeset, fn field, cs ->
      case get_change(cs, field) do
        [] -> put_change(cs, field, nil)
        _ -> cs
      end
    end)
  end
end
