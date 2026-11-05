defmodule Crew.Boxes.RebootsTest do
  @moduledoc """
  Reboots (§12.1), started by an admin: a Flatcar box's, through
  `box.restart`, and a `mac-vz` box's cache VM, through
  `cachevm.restart`. The box drains first; the command goes once no VM
  is left; the new boot ends it, and lifts the drain the reboot set.
  The test process stands in for the box's agent.
  """
  use Crew.DataCase, async: true

  import Crew.Fixtures

  alias Crew.Boxes
  alias Crew.Boxes.{Box, Reboots}
  alias CrewProtocol.Command

  setup do
    admin = Crew.Scope.for_user(user_fixture(role: "admin"))
    member = Crew.Scope.for_user(user_fixture(role: "member"))
    %{admin: admin, member: member}
  end

  defp flatcar_box(attrs \\ []) do
    box = box_fixture(Keyword.merge([type: "linux-metal"], attrs))

    box
    |> Ecto.Changeset.change(
      can_restart: true,
      boot_id: "11111111-1111-4111-8111-111111111111",
      os_version: "4757.2.3",
      reboot_required: true,
      reboot_packages: ["flatcar-4800.0.0"]
    )
    |> Repo.update!()
    |> online()
  end

  defp vz_box(cache_vm) do
    box_fixture(type: "mac-vz")
    |> Ecto.Changeset.change(cache_vm_reboot: cache_vm)
    |> Repo.update!()
    |> online()
  end

  defp online(box) do
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    box
  end

  defp live_vm(box) do
    repo = repo_fixture()
    id = CrewProtocol.uuid7()

    Repo.insert!(%Crew.VMs.VM{
      id: id,
      box_id: box.id,
      name: CrewProtocol.Names.runner_name("abcd", box.name, id),
      repo_id: repo.id,
      class_key: ["crew-m"],
      class_hash: Crew.VMs.VM.class_hash(["crew-m"]),
      size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      state: "busy",
      deadline: DateTime.add(DateTime.utc_now(), 3600),
      requested_at: DateTime.utc_now()
    })
  end

  defp destroy(vm), do: vm |> Ecto.Changeset.change(state: "destroyed") |> Repo.update!()

  defp rejoin(box, boot_id),
    do:
      Boxes.agent_joined(Repo.reload!(box), %{
        agent_version: "0.1.0",
        protocol_version: CrewProtocol.version(),
        os: "linux",
        arch: "arm64",
        boot_id: boot_id
      })

  describe "a Flatcar box" do
    test "drains, and with no VM left reboots on the boot it saw", %{admin: admin} do
      box = flatcar_box()
      assert {:ok, %Box{} = box} = Reboots.request(admin, box, :box)
      assert box.draining and box.drain_reason == "reboot"
      assert box.reboot_requested_at
      assert box.reboot_target == "box"

      assert_receive {:dispatch, %Command{type: "box.restart", payload: payload}}
      assert payload == %{boot_id: "11111111-1111-4111-8111-111111111111", force: false}
    end

    test "waits for its VMs: box.restart goes when the last one is gone", %{admin: admin} do
      box = flatcar_box()
      vm = live_vm(box)
      {:ok, _} = Reboots.request(admin, box, :box)
      refute_receive {:dispatch, %Command{type: "box.restart"}}, 50

      destroy(vm)
      Reboots.advance(box.id)
      assert_receive {:dispatch, %Command{type: "box.restart"}}
    end

    test "the new boot ends it, and lifts the drain the reboot set", %{admin: admin} do
      box = flatcar_box()
      {:ok, _} = Reboots.request(admin, box, :box)

      # An agent restart on the same boot is still waiting.
      rejoin(box, "11111111-1111-4111-8111-111111111111")
      assert Repo.reload!(box).reboot_requested_at

      rejoin(box, "22222222-2222-4222-8222-222222222222")
      box = Repo.reload!(box)
      refute box.reboot_requested_at
      refute box.reboot_target
      refute box.draining
    end

    test "a drain the admin set stays after the reboot", %{admin: admin} do
      box = flatcar_box(draining: true)
      box = box |> Ecto.Changeset.change(drain_reason: "admin") |> Repo.update!()
      {:ok, _} = Reboots.request(admin, box, :box)
      rejoin(box, "22222222-2222-4222-8222-222222222222")
      box = Repo.reload!(box)
      assert box.draining and box.drain_reason == "admin"
      refute box.reboot_requested_at
    end

    test "Reboot now stops the VMs by force and reboots at once", %{admin: admin} do
      box = flatcar_box()
      vm = live_vm(box)
      {:ok, _} = Reboots.request(admin, box, :box, now: true)

      assert_receive {:dispatch, %Command{type: "vm.stop", payload: %{vm_id: vm_id, force: true}}}
      assert vm_id == vm.id
      assert_receive {:dispatch, %Command{type: "box.restart", payload: %{force: true}}}
      assert Repo.get_by!(Crew.Audit.Event, action: "box.reboot_now", subject_id: box.id)
    end

    test "the box page can tell an update that rolled back", %{admin: admin} do
      box = flatcar_box()
      {:ok, _} = Reboots.request(admin, box, :box)
      rejoin(box, "22222222-2222-4222-8222-222222222222")

      report = %{required: false, packages: [], boot_id: "x", can_restart: true}
      Boxes.report_reboot(Repo.reload!(box), Map.put(report, :os_version, "4757.2.3"))
      assert Reboots.rolled_back?(Repo.reload!(box))

      Boxes.report_reboot(Repo.reload!(box), Map.put(report, :os_version, "4800.0.0"))
      refute Reboots.rolled_back?(Repo.reload!(box))
    end

    test "is for admins, and for a box that can restart", %{admin: admin, member: member} do
      box = flatcar_box()
      assert {:error, :unauthorized} = Reboots.request(member, box, :box)

      vz = vz_box(nil)
      assert {:error, :cannot_restart} = Reboots.request(admin, vz, :box)
      refute_receive {:dispatch, _}, 50
    end
  end

  describe "a mac-vz box's cache VM" do
    @cache %{
      "required" => true,
      "packages" => ["flatcar-4800.0.0"],
      "boot_id" => "c1c1c1c1-1111-4111-8111-111111111111"
    }

    test "drains the box, then restarts the cache VM on the boot it saw", %{admin: admin} do
      box = vz_box(@cache)
      {:ok, box} = Reboots.request(admin, box, :cache_vm)
      assert box.draining and box.reboot_target == "cache_vm"

      assert_receive {:dispatch, %Command{type: "cachevm.restart", payload: payload}}
      assert payload == %{boot_id: "c1c1c1c1-1111-4111-8111-111111111111"}
    end

    test "its new boot ends it, and lifts the drain", %{admin: admin} do
      box = vz_box(@cache)
      {:ok, _} = Reboots.request(admin, box, :cache_vm)

      report = %{required: false, packages: [], boot_id: "m", can_restart: false}

      Boxes.report_reboot(
        Repo.reload!(box),
        Map.put(report, :cache_vm, %{required: true, packages: [], boot_id: @cache["boot_id"]})
      )

      assert Repo.reload!(box).reboot_requested_at

      new = %{required: false, packages: [], boot_id: "c2c2c2c2-2222-4222-8222-222222222222"}
      Boxes.report_reboot(Repo.reload!(box), Map.put(report, :cache_vm, new))
      box = Repo.reload!(box)
      refute box.reboot_requested_at
      refute box.draining
    end

    test "a box without one can't", %{admin: admin} do
      assert {:error, :no_cache_vm} = Reboots.request(admin, vz_box(nil), :cache_vm)
      assert {:error, :no_cache_vm} = Reboots.request(admin, flatcar_box(), :cache_vm)
    end
  end
end
