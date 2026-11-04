defmodule Crew.Caches.Config do
  @moduledoc """
  The registry cache's settings, one row for the deployment (§15.3): the
  enabled hosts (a subset of `CrewProtocol.Hosts`), the cacheable
  allowlist, whether boxes use the parent cache, and the CA generation
  (§15.4), bumped by **Rotate CA**.
  """
  use Crew.Schema

  schema "cache_config" do
    field :enabled_hosts, {:array, :string}
    field :allowlist, {:array, :string}
    field :parent_enabled, :boolean, default: false
    field :ca_generation, :integer, default: 1
    timestamps()
  end

  def hosts_changeset(config, hosts) do
    config
    |> Ecto.Changeset.change(enabled_hosts: Enum.uniq(hosts))
    |> Ecto.Changeset.validate_subset(:enabled_hosts, CrewProtocol.Hosts.names(),
      message: "has a host Crew doesn't know"
    )
  end
end
