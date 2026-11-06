defmodule Crew.VMsReadsTest do
  @moduledoc "Reading VMs in bulk, and what a set of them holds of a box."
  use Crew.DataCase

  alias Crew.VMs
  alias Crew.VMs.VM

  defp vm!(box, attrs) do
    id = CrewProtocol.uuid7()
    repo = Repo.one(Crew.Repos.Repo) || repo_fixture()

    Repo.insert!(
      struct!(
        %VM{
          id: id,
          box_id: box.id,
          repo_id: repo.id,
          size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id,
          name: "vm-#{System.unique_integer([:positive])}",
          class_key: ["crew-m"],
          class_hash: VM.class_hash(["crew-m"]),
          vcpus: 4,
          memory_mib: 8192,
          disk_gib: 60,
          vmm_overhead_mib: 128,
          state: "busy",
          deadline: DateTime.add(DateTime.utc_now(), 3600),
          requested_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  test "get_many/1 reads VMs by id in one go, skipping ids that aren't there" do
    box = box_fixture()
    a = vm!(box, [])
    b = vm!(box, vcpus: 2)

    assert VMs.get_many([a.id, b.id, CrewProtocol.uuid7()]) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([a.id, b.id])

    assert VMs.get_many([]) == []
  end

  test "allocation_of/1 is what VMs hold, overhead included, as allocation/1 counts it" do
    box = box_fixture()
    vm!(box, [])
    vm!(box, vcpus: 2, memory_mib: 4096)

    assert VMs.allocation_of(VMs.for_box(box.id)) ==
             %{vcpus: 6, memory_mib: 8192 + 4096 + 256, count: 2}

    assert VMs.allocation(box.id) == VMs.allocation_of(VMs.for_box(box.id))
  end
end
