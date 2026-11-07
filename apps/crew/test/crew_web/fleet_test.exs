defmodule CrewWeb.FleetTest do
  @moduledoc "The fleet at a glance (§17.3): totals, what's provisioned over time, what needs a look."
  use Crew.DataCase

  alias CrewWeb.Fleet

  @now 1_800_000_000

  defp at(t), do: DateTime.from_unix!(t * 1_000_000, :microsecond)

  defp online(box), do: {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})

  setup do
    a = box_fixture(name: "alpha")
    b = box_fixture(name: "bravo", capabilities: capabilities(vcpus: 10, memory_mib: 32_768))
    gone = box_fixture(name: "charlie")
    online(a)
    online(b)

    vm_fixture(a, requested_at: at(@now - 120))
    vm_fixture(a, vcpus: 2, memory_mib: 4096, state: "starting", requested_at: at(@now - 10))
    vm_fixture(b, state: "idle", requested_at: at(@now - 900))
    # Still held on the offline box: it counts as provisioned, not as capacity.
    vm_fixture(gone, vcpus: 8, memory_mib: 16_384, requested_at: at(@now - 60))

    %{a: a, b: b, gone: gone}
  end

  test "totals: capacity of the online boxes, everything their VMs hold" do
    fleet = Fleet.load("30m", @now)
    t = fleet.totals

    assert t.boxes == 3
    assert t.online == 2
    assert t.cores == 18 + 10
    assert t.memory_mib == 110_592 + 32_768
    # (18 - 1) * 1.5 and (10 - 1) * 1.5 vCPUs; memory less 2 GiB and 5 % each.
    assert t.allocatable_vcpus == 25.5 + 13.5
    assert t.allocatable_memory_mib == 110_592 - 2048 - 5529 + (32_768 - 2048 - 1638)
    assert t.provisioned_vcpus == 4 + 2 + 4 + 8
    assert t.provisioned_memory_mib == 8320 + 4224 + 8320 + 16_512
    assert t.vms == %{total: 4, busy: 2, idle: 1, booting: 1, ending: 0}
  end

  test "each box has its colour, state, VMs and what they hold", %{a: a, gone: gone} do
    fleet = Fleet.load("30m", @now)
    [alpha, bravo, charlie] = fleet.boxes

    assert {alpha.box.id, alpha.online, alpha.color} == {a.id, true, "series-1"}
    assert bravo.color == "series-2"
    assert alpha.allocation == %{vcpus: 6, memory_mib: 8320 + 4224, count: 2}
    assert alpha.vms == %{total: 2, busy: 1, idle: 0, booting: 1, ending: 0}
    assert alpha.sizes == [{"m", 2}]
    assert alpha.capacity == %{vcpus: 25.5, memory_mib: 103_015}
    assert {charlie.box.id, charlie.online, charlie.issues} == {gone.id, false, [:offline]}
  end

  test "the provisioned charts stack a band per box, newest point now", %{a: a} do
    fleet = Fleet.load("30m", @now)
    assert {fleet.since, fleet.until, fleet.step} == {@now - 1800, @now, 10}

    [alpha, _bravo, _charlie] = fleet.provisioned.vcpus
    assert %{label: "alpha", kind: :area, color: "series-1"} = alpha
    assert List.last(alpha.points) == {@now, 0, 6}

    [_alpha, bravo, charlie] = fleet.provisioned.vcpus
    assert List.last(bravo.points) == {@now, 6, 10}
    assert List.last(charlie.points) == {@now, 10, 18}

    # Memory in GiB.
    [alpha_mem | _] = fleet.provisioned.memory
    assert {_, 0, gib} = List.last(alpha_mem.points)
    assert_in_delta gib, (8320 + 4224) / 1024, 0.001
    assert Enum.any?(fleet.boxes, &(&1.box.id == a.id))
  end

  test "a box's latest sample is now only if it's fresh", %{a: a, gone: gone} do
    box_metric_fixture(a, @now - 5, cpu_pct: 42.0)
    box_metric_fixture(gone, @now - 3600, cpu_pct: 99.0)

    [alpha, _bravo, charlie] = Fleet.load("30m", @now).boxes
    assert alpha.latest.cpu_pct == 42.0
    assert charlie.latest == nil
  end

  test "attention: boxes that can't take jobs for a problem, not a drain", %{a: a} do
    firewall = box_fixture(name: "delta", firewall_ok: false)
    online(firewall)
    drained = box_fixture(name: "echo", draining: true)
    online(drained)

    fleet = Fleet.load("30m", @now)

    assert Enum.map(fleet.attention, &{&1.box.name, &1.issues}) == [
             {"charlie", [:offline]},
             {"delta", [:firewall]}
           ]

    refute Enum.any?(fleet.attention, &(&1.box.id == a.id))
  end

  test "ranges: a known one sets the window and step, anything else is half an hour" do
    assert %{range: "24h", since: since, step: 360} = Fleet.load("24h", @now)
    assert since == @now - 86_400
    assert %{range: "30m"} = Fleet.load("nonsense", @now)
    assert Fleet.ranges() == ~w(30m 1h 6h 24h)
  end
end
