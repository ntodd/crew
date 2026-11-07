defmodule Crew.VMsReadsTest do
  @moduledoc "Reading VMs in bulk, and what a set of them holds of a box."
  use Crew.DataCase

  alias Crew.VMs

  defp vm!(box, attrs), do: vm_fixture(box, attrs)

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

  describe "provisioned_series/3" do
    # Unix seconds, and the DateTime for them.
    defp at(t), do: DateTime.from_unix!(t * 1_000_000, :microsecond)

    test "is what each box's VMs held over each step, time-weighted, and at the end" do
      a = box_fixture()
      b = box_fixture()
      since = 1_800_000_000

      # On a: one VM for the whole range, and one for 20 s across two steps.
      vm!(a, requested_at: at(since - 600))

      vm!(a,
        vcpus: 2,
        memory_mib: 4096,
        requested_at: at(since + 10),
        destroyed_at: at(since + 30),
        state: "destroyed"
      )

      # On b: one that comes 5 s before the end and is still booting.
      vm!(b, vcpus: 8, memory_mib: 16_384, requested_at: at(since + 55), state: "starting")

      series = VMs.provisioned_series(since, since + 60, 20)

      # Half of each of the first two steps had the 2 vCPU VM too.
      assert series[a.id] == [
               {since, 5.0, 8320 + 2112.0},
               {since + 20, 5.0, 8320 + 2112.0},
               {since + 40, 4.0, 8320.0},
               {since + 60, 4, 8320}
             ]

      # A quarter of the last step, then all of it at the end.
      assert series[b.id] == [
               {since, 0.0, 0.0},
               {since + 20, 0.0, 0.0},
               {since + 40, 2.0, 4128.0},
               {since + 60, 8, 16_512}
             ]
    end

    test "a VM from long before the range that's destroyed in it still counts" do
      box = box_fixture()
      since = 1_800_000_000

      vm!(box,
        requested_at: at(since - 3 * 86_400),
        destroyed_at: at(since + 30),
        state: "destroyed"
      )

      assert VMs.provisioned_series(since, since + 60, 20)[box.id] == [
               {since, 4.0, 8320.0},
               {since + 20, 2.0, 4160.0},
               {since + 40, 0.0, 0.0},
               {since + 60, 0, 0}
             ]
    end

    test "a step cut short by the range's end is weighted over what's left of it" do
      box = box_fixture()
      since = 1_800_000_000
      vm!(box, requested_at: at(since - 900), destroyed_at: at(since - 300), state: "destroyed")
      vm!(box, requested_at: at(since + 45))

      assert VMs.provisioned_series(since, since + 50, 20) == %{
               box.id => [
                 {since, 0.0, 0.0},
                 {since + 20, 0.0, 0.0},
                 {since + 40, 2.0, 4160.0},
                 {since + 50, 4, 8320}
               ]
             }

      assert VMs.provisioned_series(since, since + 40, 20) == %{}
    end
  end
end
