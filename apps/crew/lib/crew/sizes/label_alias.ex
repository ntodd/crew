defmodule Crew.Sizes.LabelAlias do
  @moduledoc "A whole label set mapped to a size and arch (§7.3)."
  use Crew.Schema

  schema "label_aliases" do
    field :labels, {:array, :string}
    field :labels_key, :string
    belongs_to :size, Crew.Sizes.Size
    field :arch, :string, default: "any"
    timestamps()
  end

  def changeset(label_alias, attrs) do
    label_alias
    |> cast(attrs, [:labels, :size_id, :arch])
    |> validate_required([:labels, :size_id, :arch])
    |> validate_inclusion(:arch, ~w(any x64 arm64))
    |> normalize_labels()
    |> unique_constraint(:labels_key, name: :label_aliases_labels_key_index, error_key: :labels)
    |> assoc_constraint(:size)
  end

  defp normalize_labels(changeset) do
    case get_change(changeset, :labels) do
      nil ->
        changeset

      labels ->
        key = CrewProtocol.Labels.key(labels)

        cond do
          key == [] ->
            add_error(changeset, :labels, "can't be empty")

          Enum.any?(key, &CrewProtocol.Labels.crew_label?/1) ->
            add_error(changeset, :labels, "can't contain a Crew label")

          Enum.any?(key, &(not Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,99}\z/, &1))) ->
            add_error(changeset, :labels, "must be runner labels")

          true ->
            changeset |> put_change(:labels, key) |> put_change(:labels_key, Enum.join(key, ","))
        end
    end
  end
end
