defmodule Crew.SizesTest do
  use Crew.DataCase

  alias Crew.Sizes

  test "the migration inserts the spec's sizes, with m the default" do
    assert Enum.map(Sizes.list(), & &1.name) == ~w(xs s m l xl)
    assert %{name: "m", vcpus: 4, memory_mib: 8192, disk_gib: 60} = Sizes.default()
  end

  test "for_parse/0 is what Labels.parse/3 takes" do
    sizes = Sizes.for_parse()
    assert Enum.all?(sizes, &match?(%{id: _, name: _, is_default: _, retired: false}, &1))
  end

  describe "creating and editing sizes" do
    setup do: %{admin: Crew.Scope.for_user(user_fixture(role: "admin"))}

    test "validates the size rules", %{admin: admin} do
      assert {:error, changeset} =
               Sizes.create(admin, %{name: "x64", vcpus: 3, memory_mib: 1000, disk_gib: 5})

      errors = errors_on(changeset)
      assert errors[:name] && errors[:vcpus] && errors[:memory_mib] && errors[:disk_gib]
    end

    test "names are unique", %{admin: admin} do
      assert {:error, changeset} =
               Sizes.create(admin, %{name: "m", vcpus: 2, memory_mib: 4096, disk_gib: 40})

      assert errors_on(changeset)[:name]
    end

    test "making one the default unsets the old one", %{admin: admin} do
      {:ok, big} =
        Sizes.create(admin, %{name: "big", vcpus: 32, memory_mib: 65_536, disk_gib: 200})

      {:ok, _} = Sizes.make_default(admin, big)
      assert Sizes.default().name == "big"
      assert Enum.count(Sizes.list(), & &1.is_default) == 1
    end

    test "only admins", %{admin: _} do
      member = Crew.Scope.for_user(user_fixture())

      assert {:error, :unauthorized} =
               Sizes.create(member, %{name: "big", vcpus: 2, memory_mib: 4096, disk_gib: 40})
    end

    test "the default can't be retired", %{admin: admin} do
      assert {:error, :default} = Sizes.retire(admin, Sizes.default())
    end

    test "retired sizes parse as unsatisfiable", %{admin: admin} do
      l = Enum.find(Sizes.list(), &(&1.name == "l"))
      {:ok, _} = Sizes.retire(admin, l)

      assert CrewProtocol.Labels.parse(["crew-l"], Sizes.for_parse(), Sizes.aliases_for_parse()) ==
               {:unsatisfiable, "size l retired"}
    end
  end

  describe "aliases" do
    setup do: %{admin: Crew.Scope.for_user(user_fixture(role: "admin"))}

    test "map an exact label set to a size and arch", %{admin: admin} do
      m = Sizes.default()

      {:ok, _} =
        Sizes.create_alias(admin, %{
          labels: ["Self-Hosted", "linux", "x64"],
          size_id: m.id,
          arch: "x64"
        })

      assert {:ours, %{size_id: id, arch: :x64, alias: true}} =
               CrewProtocol.Labels.parse(
                 ["self-hosted", "linux", "x64"],
                 Sizes.for_parse(),
                 Sizes.aliases_for_parse()
               )

      assert id == m.id
    end

    test "can't contain a Crew label, and are unique as a set", %{admin: admin} do
      m = Sizes.default()

      assert {:error, cs} =
               Sizes.create_alias(admin, %{labels: ["crew-m"], size_id: m.id, arch: "any"})

      assert errors_on(cs)[:labels]

      {:ok, _} = Sizes.create_alias(admin, %{labels: ["a", "b"], size_id: m.id, arch: "any"})

      assert {:error, cs} =
               Sizes.create_alias(admin, %{labels: ["B", "a"], size_id: m.id, arch: "any"})

      assert errors_on(cs)[:labels]
    end
  end
end
