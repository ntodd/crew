defmodule Crew.Sizes.Size do
  @moduledoc "A named vCPU / memory / disk allocation (§7.1)."
  use Crew.Schema

  schema "sizes" do
    field :name, :string
    field :vcpus, :integer
    field :memory_mib, :integer
    field :disk_gib, :integer
    field :disk_iops, :integer
    field :disk_bandwidth_mbps, :integer
    field :net_bandwidth_mbps, :integer
    field :is_default, :boolean, default: false
    field :retired_at, :utc_datetime_usec
    timestamps()
  end

  @fields ~w(name vcpus memory_mib disk_gib disk_iops disk_bandwidth_mbps net_bandwidth_mbps)a

  def changeset(size, attrs) do
    size
    |> cast(attrs, @fields)
    |> validate_required([:name, :vcpus, :memory_mib, :disk_gib])
    |> validate_rules()
    |> validate_number(:disk_iops, greater_than: 0, less_than_or_equal_to: 1_000_000)
    |> validate_number(:disk_bandwidth_mbps, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_number(:net_bandwidth_mbps, greater_than: 0, less_than_or_equal_to: 100_000)
    |> unique_constraint(:name)
  end

  # The rules are CrewProtocol's, shared with the agent's vm.start checks.
  defp validate_rules(changeset) do
    size = Map.new(@fields, &{&1, get_field(changeset, &1)})

    case CrewProtocol.Sizes.validate(size) do
      :ok -> changeset
      {:error, errors} -> Enum.reduce(errors, changeset, fn {f, m}, cs -> add_error(cs, f, m) end)
    end
  end

  def retired?(%__MODULE__{retired_at: at}), do: not is_nil(at)

  @doc "The size's limits for vm.start, only those set."
  def limits(%__MODULE__{} = size) do
    for f <- [:disk_iops, :disk_bandwidth_mbps, :net_bandwidth_mbps],
        v = Map.get(size, f),
        not is_nil(v),
        into: %{},
        do: {f, v}
  end
end
