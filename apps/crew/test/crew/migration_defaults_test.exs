defmodule Crew.MigrationDefaultsTest do
  # The defaults are inserted schemaless, so each adapter's encoding has
  # to be done by hand; these read them back typed, as the schemas will.
  use Crew.DataCase

  test "the default sizes load with their types" do
    rows =
      Repo.all(
        from s in "sizes",
          order_by: s.vcpus,
          select: %{
            name: s.name,
            vcpus: type(s.vcpus, :integer),
            is_default: type(s.is_default, :boolean),
            inserted_at: type(s.inserted_at, :utc_datetime_usec)
          }
      )

    assert Enum.map(rows, & &1.name) == ~w(xs s m l xl)
    assert [%{name: "m"}] = Enum.filter(rows, & &1.is_default)
    assert Enum.all?(rows, &match?(%DateTime{}, &1.inserted_at))
  end

  test "the cache config singleton loads with its types" do
    [config] =
      Repo.all(
        from c in "cache_config",
          select: %{
            enabled_hosts: type(c.enabled_hosts, {:array, :string}),
            parent_enabled: type(c.parent_enabled, :boolean)
          }
      )

    assert config.enabled_hosts == CrewProtocol.Hosts.names()
    assert config.parent_enabled == false
  end
end
