defmodule CrewAgent.FirecrackerKVMTest do
  @moduledoc """
  Real Firecracker VMs on a Linux host with KVM: the agent's own start
  path (image, clone, lease, fc.json) through a real crew-vmctl socket,
  systemd unit and jailer, booting the guest image, whose crew-guest
  fetches its payload from the guest API on 10.199.0.1:7777.

  `native/crew-vmctl/kvm/run.sh` sets the host up (the pinned Firecracker,
  crew-vmctl, its units, crew-net) and runs this with `mix test --only
  kvm`, as root: crew-vmctl requires the clone and kernel to be the
  connecting uid's, and here that's root.

      CREW_REAL_IMAGE_DIR=<dir with Image or kernel, and rootfs.ext4>
  """
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Config, Handler, Images, VM, VMs}
  alias CrewAgent.Driver.Firecracker
  alias CrewAgent.Driver.Firecracker.Monitor
  alias CrewAgent.VMs.Cleanup

  @moduletag :kvm
  @moduletag timeout: 300_000

  setup_all do
    image_dir = System.get_env("CREW_REAL_IMAGE_DIR") || raise "CREW_REAL_IMAGE_DIR isn't set"
    data = System.get_env("CREW_KVM_DATA_DIR", "/srv/crew")
    base = Config.get()

    config = %{
      base
      | driver: "firecracker",
        data_dir: data,
        vmctl_socket: System.get_env("CREW_VMCTL_SOCKET", "/run/crew/vmctl.sock"),
        dev: true,
        dev_image_dir: image_dir
    }

    Config.put(config)
    File.mkdir_p!(Config.vms_dir(config))
    File.mkdir_p!(Config.images_dir(config))

    # Guests reach the API at 10.199.0.1:7777 (crew0, from crew-net).
    start_supervised!(%{
      id: :kvm_guest_api,
      start: {CrewAgent.GuestAPI, :start_link, [[ip: {10, 199, 0, 1}, port: 7777]]},
      type: :supervisor
    })

    start_supervised!(Monitor)
    on_exit(fn -> Config.put(base) end)

    image_id = CrewProtocol.uuid7()

    arch =
      if :erlang.system_info(:system_architecture)
         |> to_string()
         |> String.starts_with?("aarch64"),
         do: "arm64",
         else: "x64"

    :ok = Images.prepare(%{id: image_id, version: "0.0.0-dev", arch: arch})
    %{config: config, image_id: image_id, arch: arch}
  end

  setup do
    attach()
    :ok
  end

  defp start(ctx, overrides \\ %{}) do
    cmd = command(ctx, overrides)
    assert :ok = Handler.handle(cmd)
    cmd.payload.vm_id
  end

  defp command(ctx, overrides \\ %{}) do
    start_command(
      Map.merge(
        %{
          "size" => %{"vcpus" => 2, "memory_mib" => 1024, "disk_gib" => 10},
          "image" => image(ctx)
        },
        overrides
      )
    )
  end

  defp image(ctx) do
    %{
      "id" => ctx.image_id,
      "version" => "0.0.0-dev",
      "arch" => ctx.arch,
      "manifest_sha256" => String.duplicate("0", 64)
    }
  end

  defp lease(ctx, vm_id) do
    ctx.config
    |> Config.vm_dir(vm_id)
    |> Path.join("vm.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("lease_index")
  end

  # Conformance item 8: nothing of the VM is left but its record.
  defp assert_clean(ctx, vm_id, lease) do
    refute Firecracker.alive?(vm_id)

    assert {:ok, %{"vm" => %{"state" => "gone"}}} =
             Firecracker.vmctl(%{"verb" => "status", "vm_id" => vm_id})

    refute File.exists?("/sys/class/net/crewt#{lease}"), "the tap is still there"
    refute File.exists?(Path.join([ctx.config.data_dir, "jail", "firecracker", vm_id]))
    dir = Config.vm_dir(ctx.config, vm_id)
    refute File.exists?(Path.join(dir, "rootfs.ext4"))
    refute File.exists?(Path.join(dir, "fc.json"))
    assert File.exists?(Path.join(dir, "exited.json"))
    assert File.exists?(Path.join(dir, "console.log"))
  end

  test "the host meets §11.3's requirements and the packet filter verifies" do
    {:ok, caps} = Firecracker.capabilities()

    IO.puts(
      "\n  capabilities: #{inspect(Map.take(caps, [:driver_version, :vcpus, :memory_mib, :features, :virtualized, :hypervisor_vendor]))}"
    )

    assert caps.firewall_ok
    assert caps.driver_version =~ ~r/^firecracker 1\.17\.0/

    # What each start pays for crew-vmctl's own check (README).
    ms =
      for _ <- 1..5 do
        {us, {:ok, _}} = :timer.tc(fn -> Firecracker.vmctl(%{"verb" => "nft-verify"}) end)
        div(us, 1000)
      end

    IO.puts("  nft-verify took #{Enum.join(ms, ", ")} ms")

    for f <- ~w(kvm tun cgroup2 xfs_reflink systemd),
        do: assert(f in caps.features, "missing #{f}")

    assert {:ok, _} = CrewProtocol.Event.new("box.capabilities", caps)
  end

  test "with an echo service, VMs wait for site4 to hold the egress address, which is loaded at once",
       ctx do
    Application.put_env(:crew_agent, :egress_echo_url, "https://echo.invalid")
    :persistent_term.erase({CrewAgent.Site, :egress})
    refute Monitor.verify()

    cmd = command(ctx)
    assert {:error, "start_failed", why} = Handler.handle(cmd)
    assert why =~ "firewall_not_ready"

    CrewAgent.Site.record_egress(ctx.config, "198.51.100.77")
    assert Monitor.verify()
    assert Monitor.status().site4_egress == "198.51.100.77"
  after
    Application.delete_env(:crew_agent, :egress_echo_url)
    :persistent_term.erase({CrewAgent.Site, :egress})
    Monitor.reset()
  end

  test "a cleanup crew-vmctl can't do keeps the VM's record, lease and jail until a retry works",
       ctx do
    vm_id = start(ctx, %{"deadline" => System.os_time(:second) + 15})
    lease = lease(ctx, vm_id)
    jail = Path.join([ctx.config.data_dir, "jail", "firecracker", vm_id])
    # Without its pair it never gets its payload, so it stays up.
    assert {:ok, _} = Firecracker.vmctl(%{"verb" => "pair-del", "lease_index" => lease})

    # crew-vmctl is out of reach when systemd kills it at its deadline.
    Config.put(%{ctx.config | vmctl_socket: "/run/crew/nowhere.sock"})
    exited = await("vm.exited", &(&1.vm_id == vm_id), 60_000)
    assert exited.payload.reason == "killed_deadline"
    assert exited.payload.cleanup == "error"
    assert Cleanup.pending?(vm_id)
    assert File.dir?(jail)
    assert {:error, :taken} = CrewAgent.Net.claim(CrewProtocol.uuid7(), lease)

    Config.put(ctx.config)
    Cleanup.retry_all()
    refute Cleanup.pending?(vm_id)
    assert_clean(ctx, vm_id, lease)
    assert {:ok, _} = CrewAgent.Net.claim(other = CrewProtocol.uuid7(), lease)
    CrewAgent.Net.release(other)
  after
    Config.put(ctx.config)
    Monitor.verify()
  end

  test "a jail the agent has no record of is cleaned up", ctx do
    orphan = CrewProtocol.uuid7()
    jail = Path.join([ctx.config.data_dir, "jail", "firecracker", orphan])
    File.mkdir_p!(Path.join(jail, "root"))
    assert {:ok, ids} = Firecracker.leftovers()
    assert orphan in ids
    Cleanup.reconcile()
    refute File.exists?(jail)
  end

  @tamper "crew_kvm_test"

  test "a ruleset that stops verifying cuts running VMs off, and nothing starts until it verifies again",
       ctx do
    nft =
      System.find_executable("nft") || flunk("the :kvm suite needs nft, to change the ruleset")

    vm_id = start(ctx)
    lease = lease(ctx, vm_id)
    # Without its pair it never gets its payload, so it stays up.
    assert {:ok, _} = Firecracker.vmctl(%{"verb" => "pair-del", "lease_index" => lease})

    # Someone adds a rule.
    {_, 0} =
      System.cmd(nft, [
        "add",
        "rule",
        "inet",
        "crew",
        "input",
        "accept",
        "comment",
        ~s("#{@tamper}")
      ])

    # crew-vmctl's start checks for itself, whatever the agent last saw.
    assert {:error, "start_failed", why} = Handler.handle(command(ctx))
    assert why =~ "nft_mismatch"

    Monitor.tick()
    exited = await("vm.exited", &(&1.vm_id == vm_id), 15_000)
    assert exited.payload.reason == "killed_stop"
    assert exited.payload.detail == "firewall_not_verified"
    assert {:error, "start_failed", why} = Handler.handle(command(ctx))
    assert why =~ "firewall_not_ready"

    untamper(nft)
    Monitor.tick()
    assert Monitor.firewall_ok?()
    assert_clean(ctx, vm_id, lease)
  after
    if nft = System.find_executable("nft"), do: untamper(nft)
  end

  defp untamper(nft) do
    {out, 0} = System.cmd(nft, ["-j", "-a", "list", "chain", "inet", "crew", "input"])

    for %{"rule" => %{"comment" => @tamper, "handle" => h}} <- Jason.decode!(out)["nftables"] do
      {_, 0} =
        System.cmd(nft, ["delete", "rule", "inet", "crew", "input", "handle", to_string(h)])
    end

    :ok
  end

  test "a real VM boots and fetches its payload, then powers off by itself", ctx do
    started = System.monotonic_time(:millisecond)
    vm_id = start(ctx)

    IO.puts(
      "\n  vm.start was answered #{System.monotonic_time(:millisecond) - started} ms after it came"
    )

    lease = lease(ctx, vm_id)
    assert Firecracker.alive?(vm_id)
    assert File.exists?("/sys/class/net/crewt#{lease}")

    booted = await("vm.state", &(&1.vm_id == vm_id and &1.state == "booted"), 60_000)
    ms = System.monotonic_time(:millisecond) - started
    IO.puts("\n  crew-guest fetched its payload #{ms} ms after vm.start")
    refute Map.get(booted.payload, :detail), "a first fetch has no detail"

    # The example JIT config isn't one GitHub issued: crew-guest refuses
    # to start the runner and powers off, which Firecracker reports as a
    # clean exit.
    exited = await("vm.exited", &(&1.vm_id == vm_id), 60_000)

    IO.puts(
      "  it exited #{exited.payload.reason}, status #{exited.payload.exit_status}, after #{exited.payload.uptime_ms} ms"
    )

    assert exited.payload.exit_status == 0
    assert exited.payload.reason == "boot_failed"
    assert exited.payload.cleanup == "ok"
    assert_clean(ctx, vm_id, lease)

    # The serial console (quiet loglevel=4, so little), moved into vms/.
    console = File.read!(Path.join(Config.vm_dir(ctx.config, vm_id), "console.log"))

    IO.puts(
      "  console.log: #{byte_size(console)} bytes: #{inspect(String.slice(console, 0, 300))}"
    )
  end

  test "a forced stop kills it at once", ctx do
    vm_id = start(ctx)
    lease = lease(ctx, vm_id)
    assert {:ok, %{rss_mib: rss}} = Firecracker.stats(vm_id)
    assert rss > 0

    # jailer gives the chroot to the VM's uid and gid; the directory it's
    # in stays root's (native/crew-vmctl/README.md).
    jail = Path.join([ctx.config.data_dir, "jail", "firecracker", vm_id])
    assert %File.Stat{uid: 0, gid: 0} = File.stat!(jail)
    assert %File.Stat{uid: uid, gid: gid} = File.stat!(Path.join(jail, "root"))
    assert {uid, gid} == {200_000 + lease, 200_000 + lease}

    stopped = System.monotonic_time(:millisecond)
    VMs.stop(vm_id, true, 0)
    exited = await("vm.exited", &(&1.vm_id == vm_id), 15_000)
    ms = System.monotonic_time(:millisecond) - stopped
    IO.puts("\n  a forced stop's vm.exited came #{ms} ms after vm.stop")
    assert exited.payload.reason == "killed_stop"
    assert exited.payload.exit_status == 137
    assert ms < 5_000
    assert_clean(ctx, vm_id, lease)
  end

  test "without its pair the VM is cut off, and systemd kills it at the deadline while the agent is away",
       ctx do
    vm_id = start(ctx, %{"deadline" => System.os_time(:second) + 20})
    lease = lease(ctx, vm_id)

    # vm_pairs fails closed (§14.2): with the pair gone, nothing from the
    # VM gets past prerouting, so its payload never comes.
    assert {:ok, _} = Firecracker.vmctl(%{"verb" => "pair-del", "lease_index" => lease})

    # The agent goes away (this VM's server does): only systemd's
    # RuntimeMaxSec is left to enforce the deadline (§10.7).
    pid = VM.whereis(vm_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    wait_until(fn -> not Firecracker.alive?(vm_id) end, 60_000)
    assert {:ok, %{code: 143, reason: "killed_deadline"}} = Firecracker.exit_status(vm_id)

    # The agent comes back and adopts it: dead, and killed at its deadline.
    VMs.adopt_all()
    exited = await("vm.exited", &(&1.vm_id == vm_id), 30_000)
    assert exited.payload.reason == "killed_deadline"
    assert exited.payload.cleanup == "ok"
    assert_clean(ctx, vm_id, lease)
  end

  defp wait_until(fun, ms) do
    cond do
      fun.() ->
        :ok

      ms <= 0 ->
        flunk("timed out")

      true ->
        Process.sleep(250)
        wait_until(fun, ms - 250)
    end
  end
end
