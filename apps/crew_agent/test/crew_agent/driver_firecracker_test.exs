defmodule CrewAgent.Driver.FirecrackerTest do
  @moduledoc """
  The Firecracker driver against a fake crew-vmctl and fake /sys, /dev
  and /proc trees. Real VMs are `mix test --only kvm`
  (`firecracker_kvm_test.exs`).
  """
  use ExUnit.Case, async: false

  alias CrewAgent.{Config, FakeVmctl}
  alias CrewAgent.Driver.Firecracker
  alias CrewAgent.Driver.Firecracker.Monitor

  setup do
    base = Config.get()
    # Unix socket paths are short on macOS.
    tmp = if match?({:unix, :darwin}, :os.type()), do: "/private/tmp", else: "/tmp"
    root = "#{tmp}/cfc#{System.unique_integer([:positive])}"
    data = Path.join(root, "data")
    File.mkdir_p!(Path.join(data, "vms"))
    File.mkdir_p!(Path.join(data, "agent"))

    for {path, body} <- [
          {"sys/fs/cgroup/cgroup.controllers", "cpuset cpu io memory pids\n"},
          {"sys/devices/system/cpu/online", "0-7\n"},
          {"dev/kvm", ""},
          {"dev/net/tun", ""},
          {"proc/meminfo", "MemTotal:       16384000 kB\nMemAvailable:   12000000 kB\n"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), body)
    end

    config = %{
      base
      | driver: "firecracker",
        data_dir: data,
        vmctl_socket: Path.join(root, "vmctl.sock"),
        sys: Path.join(root, "sys"),
        devfs: Path.join(root, "dev"),
        proc: Path.join(root, "proc")
    }

    Config.put(config)
    :persistent_term.erase({Monitor, :firewall_ok})

    on_exit(fn ->
      Config.put(base)
      :persistent_term.erase({Monitor, :firewall_ok})
      File.rm_rf!(root)
    end)

    %{config: config, root: root, data: data}
  end

  defp vmctl(%{config: config}, answer \\ fn _ -> %{"ok" => true} end) do
    start_supervised!({FakeVmctl, {config.vmctl_socket, answer, self()}})
    :ok
  end

  defp spec(config, limits \\ %{}) do
    vm_id = CrewProtocol.uuid7()
    vm_dir = Config.vm_dir(config, vm_id)
    File.mkdir_p!(vm_dir)
    clone = Path.join(vm_dir, "rootfs.ext4")
    File.write!(clone, "")
    lease = CrewAgent.Net.lease(3)

    File.write!(
      Path.join(vm_dir, "vm.json"),
      Jason.encode!(%{"vm_id" => vm_id, "lease_index" => lease.index})
    )

    %{
      vm_id: vm_id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      limits: limits,
      image: %{id: CrewProtocol.uuid7()},
      clone: clone,
      boot_args: "console=ttyS0 panic=1 crew.vm=#{vm_id}",
      net: lease,
      guest_socket: Path.join(vm_dir, "guest.sock"),
      guest_token: "t",
      guest_api: "http://10.199.0.1:7777",
      deadline: System.os_time(:second) + 3600,
      console_log: Path.join(vm_dir, "console.log"),
      vm_dir: vm_dir
    }
  end

  defp cgroup(ctx, vm_id, files) do
    dir = Path.join([ctx.root, "sys/fs/cgroup/system.slice", "crew-vm-#{vm_id}.service"])
    File.mkdir_p!(dir)
    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
    dir
  end

  describe "start" do
    test "adds the tap and the pair, writes fc.json and starts the unit, in that order", ctx do
      vmctl(ctx)
      spec = spec(ctx.config)
      assert :ok = Firecracker.start(spec)

      assert [
               %{"verb" => "tap-add", "lease_index" => 3},
               %{"verb" => "pair-add", "lease_index" => 3},
               %{"verb" => "start", "vm_id" => vm_id}
             ] = FakeVmctl.requests()

      assert vm_id == spec.vm_id
      fc = spec.vm_dir |> Path.join("fc.json") |> File.read!() |> Jason.decode!()

      # Firecracker's own format (§11.3), with host paths; crew-vmctl
      # checks it and adds the logger and metrics (native/crew-vmctl).
      assert fc == %{
               "boot-source" => %{
                 "kernel_image_path" => Path.join([ctx.data, "images", spec.image.id, "kernel"]),
                 "boot_args" => spec.boot_args
               },
               "drives" => [
                 %{
                   "drive_id" => "rootfs",
                   "path_on_host" => spec.clone,
                   "is_root_device" => true,
                   "is_read_only" => false
                 }
               ],
               "machine-config" => %{"vcpu_count" => 4, "mem_size_mib" => 8192, "smt" => false},
               "network-interfaces" => [
                 %{"iface_id" => "eth0", "host_dev_name" => "crewt3", "guest_mac" => spec.net.mac}
               ],
               "entropy" => %{}
             }

      assert File.stat!(Path.join(spec.vm_dir, "fc.json")).mode |> Bitwise.band(0o777) == 0o640
    end

    test "the size's limits become rate limiters (§7.1): Mbit/s and IOPS, refilled each second",
         ctx do
      vmctl(ctx)

      spec =
        spec(ctx.config, %{disk_iops: 3000, disk_bandwidth_mbps: 800, net_bandwidth_mbps: 1000})

      assert :ok = Firecracker.start(spec)
      fc = spec.vm_dir |> Path.join("fc.json") |> File.read!() |> Jason.decode!()
      [drive] = fc["drives"]
      [nic] = fc["network-interfaces"]

      assert drive["rate_limiter"] == %{
               "bandwidth" => %{"size" => 100_000_000, "refill_time" => 1000},
               "ops" => %{"size" => 3000, "refill_time" => 1000}
             }

      net = %{"bandwidth" => %{"size" => 125_000_000, "refill_time" => 1000}}
      assert nic["rx_rate_limiter"] == net and nic["tx_rate_limiter"] == net
    end

    test "a pair that can't be added aborts the start (§11.2)", ctx do
      vmctl(ctx, fn
        %{"verb" => "pair-add"} ->
          %{"ok" => false, "error" => "failed", "detail" => "nft: no table"}

        _ ->
          %{"ok" => true}
      end)

      assert {:error, "failed: nft: no table"} = Firecracker.start(spec(ctx.config))
      refute Enum.any?(FakeVmctl.requests(), &(&1["verb"] == "start"))
    end

    test "a refused start is an error with crew-vmctl's code", ctx do
      vmctl(ctx, fn
        %{"verb" => "start"} ->
          %{"ok" => false, "error" => "invalid_config", "detail" => "fc.json: smt must be false"}

        _ ->
          %{"ok" => true}
      end)

      assert {:error, "invalid_config: fc.json: smt must be false"} =
               Firecracker.start(spec(ctx.config))
    end

    test "with crew-vmctl down, it fails rather than hangs", ctx do
      assert {:error, "unreachable: " <> _} = Firecracker.start(spec(ctx.config))
    end
  end

  test "stop: graceful or forced; a VM that's gone is fine", ctx do
    vmctl(ctx, fn
      %{"vm_id" => "gone"} -> %{"ok" => false, "error" => "not_found", "detail" => ""}
      _ -> %{"ok" => true}
    end)

    assert :ok = Firecracker.stop("a", false)
    assert :ok = Firecracker.stop("a", true)
    assert :ok = Firecracker.stop("gone", true)

    assert [
             %{"verb" => "stop", "vm_id" => "a", "force" => false},
             %{"verb" => "stop", "vm_id" => "a", "force" => true},
             %{"verb" => "stop", "vm_id" => "gone"}
           ] = FakeVmctl.requests()
  end

  test "alive? holds until systemd removes the unit's cgroup", ctx do
    vm_id = CrewProtocol.uuid7()
    refute Firecracker.alive?(vm_id)
    dir = cgroup(ctx, vm_id, [{"cgroup.events", "populated 1\nfrozen 0\n"}])
    assert Firecracker.alive?(vm_id)

    # The VMM is gone and the cgroup empty for a moment before systemd
    # runs ExecStopPost in it, which writes the exit record: still alive.
    File.write!(Path.join(dir, "cgroup.events"), "populated 0\nfrozen 0\n")
    assert Firecracker.alive?(vm_id)
    File.rm_rf!(dir)
    refute Firecracker.alive?(vm_id)
  end

  test "list is crew-vmctl's", ctx do
    vmctl(ctx, fn %{"verb" => "list"} -> %{"ok" => true, "vms" => ["a", "b"]} end)
    assert {:ok, ["a", "b"]} = Firecracker.list()
  end

  test "stats come from the unit's cgroup: CPU since the last sample, memory now", ctx do
    start_supervised!({Monitor, interval: :manual})
    vm_id = CrewProtocol.uuid7()

    dir =
      cgroup(ctx, vm_id, [
        {"cpu.stat", "usage_usec 1000000\nuser_usec 800000\nsystem_usec 200000\n"},
        {"memory.current", "#{1100 * 1024 * 1024}\n"}
      ])

    assert {:ok, %{cpu_pct: first, rss_mib: 1100}} = Firecracker.stats(vm_id)
    assert first == 0.0
    Process.sleep(200)
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec 1200000\n")
    assert {:ok, %{cpu_pct: pct}} = Firecracker.stats(vm_id)
    # 0.2 s of CPU in about 0.2 s: about one CPU's worth.
    assert pct > 50.0 and pct < 110.0
    assert {:error, :not_running} = Firecracker.stats(CrewProtocol.uuid7())
  end

  test "how the unit ended, in the protocol's words", ctx do
    record = fn result, code, status, n ->
      %{
        "service_result" => result,
        "exit_code" => code,
        "exit_status" => status,
        "code" => n,
        "at" => 1
      }
    end

    answers = %{
      "poweroff" => record.("success", "exited", "0", 0),
      "crashed" => record.("exit-code", "exited", "1", 1),
      "deadline" => record.("timeout", "killed", "TERM", 143),
      "killed" => record.("signal", "killed", "KILL", 137),
      "stopped" => record.("success", "killed", "TERM", 143),
      "oom" => record.("oom-kill", "killed", "KILL", 137)
    }

    vmctl(ctx, fn
      %{"verb" => "status", "vm_id" => "running"} ->
        %{"ok" => true, "vm" => %{"vm_id" => "running", "state" => "active"}}

      %{"verb" => "status", "vm_id" => id} ->
        %{"ok" => true, "vm" => %{"vm_id" => id, "state" => "gone", "exited" => answers[id]}}
    end)

    assert Firecracker.exit_status("running") == :unknown
    assert {:ok, %{code: 0, reason: nil}} = Firecracker.exit_status("poweroff")
    assert {:ok, %{code: 1, reason: nil}} = Firecracker.exit_status("crashed")
    assert {:ok, %{code: 143, reason: "killed_deadline"}} = Firecracker.exit_status("deadline")
    assert {:ok, %{code: 137, reason: "killed_stop"}} = Firecracker.exit_status("killed")
    assert {:ok, %{code: 143, reason: "killed_stop"}} = Firecracker.exit_status("stopped")
    assert {:ok, %{code: 137, reason: nil}} = Firecracker.exit_status("oom")
  end

  test "cleanup asks crew-vmctl, drops the lease's pair and tap, and the token's file", ctx do
    vmctl(ctx)
    spec = spec(ctx.config)
    File.write!(Path.join(spec.vm_dir, "fc.json"), "{}")
    assert :ok = Firecracker.cleanup(spec.vm_id)

    assert [
             %{"verb" => "cleanup", "vm_id" => vm_id},
             %{"verb" => "pair-del", "lease_index" => 3},
             %{"verb" => "tap-del", "lease_index" => 3}
           ] = FakeVmctl.requests()

    assert vm_id == spec.vm_id
    refute File.exists?(Path.join(spec.vm_dir, "fc.json"))
  end

  test "cleanup is safe for a VM that never got a directory", ctx do
    vmctl(ctx)
    assert :ok = Firecracker.cleanup(CrewProtocol.uuid7())
    assert [%{"verb" => "cleanup"}] = FakeVmctl.requests()
  end

  describe "capabilities" do
    defp healthy(systemd \\ 260) do
      fn
        %{"verb" => "info"} ->
          %{
            "ok" => true,
            "info" => %{"vmctl" => "0.1.0", "firecracker" => "1.17.0", "systemd" => systemd}
          }

        %{"verb" => "nft-verify"} ->
          %{"ok" => true}
      end
    end

    test "come from this host and crew-vmctl (§8.3, §11.3)", ctx do
      vmctl(ctx, healthy())
      {:ok, caps} = Firecracker.capabilities()

      assert caps.driver == "firecracker"
      assert caps.driver_version == "firecracker 1.17.0, crew-vmctl 0.1.0"
      assert caps.vcpus == 8
      assert caps.memory_mib == 16_000
      assert caps.max_vcpus_per_vm == 8
      assert caps.max_memory_mib_per_vm == 16_000 - 2048 - 800
      assert caps.vmm_overhead_mib == 64
      assert caps.vm_area_mib > 0
      assert caps.firewall_ok
      assert caps.guest_arch in ["arm64", "x64"]
      assert "kvm" in caps.features and "tun" in caps.features and "cgroup2" in caps.features
      assert "systemd" in caps.features and "rate_limits" in caps.features
      assert {:ok, _} = CrewProtocol.Event.new("box.capabilities", caps)
    end

    test "say what's missing", ctx do
      vmctl(ctx, healthy(249))
      File.rm!(Path.join(ctx.root, "dev/kvm"))
      File.rm!(Path.join(ctx.root, "sys/fs/cgroup/cgroup.controllers"))
      {:ok, caps} = Firecracker.capabilities()
      refute "kvm" in caps.features
      refute "cgroup2" in caps.features
      refute "systemd" in caps.features
      assert "tun" in caps.features
    end

    test "a ruleset that doesn't verify makes the box ineligible (§14.2)", ctx do
      vmctl(ctx, fn
        %{"verb" => "nft-verify"} ->
          %{"ok" => false, "error" => "nft_mismatch", "detail" => "chain forward differs"}

        req ->
          healthy().(req)
      end)

      {:ok, caps} = Firecracker.capabilities()
      refute caps.firewall_ok
    end

    test "with crew-vmctl down the firewall isn't verified", _ctx do
      {:ok, caps} = Firecracker.capabilities()
      refute caps.firewall_ok
      assert caps.driver_version == "unknown"
    end
  end

  describe "the monitor" do
    test "verifies the ruleset at start and on each tick (§14.2)", ctx do
      verdict = :counters.new(1, [])

      vmctl(ctx, fn %{"verb" => "nft-verify"} ->
        if :counters.get(verdict, 1) == 0,
          do: %{"ok" => true},
          else: %{"ok" => false, "error" => "nft_mismatch", "detail" => "x"}
      end)

      pid = start_supervised!({Monitor, interval: :manual})
      assert Monitor.tick(pid) == :ok
      assert Monitor.firewall_ok?()
      :counters.put(verdict, 1, 1)
      Monitor.tick(pid)
      refute Monitor.firewall_ok?()
    end

    test "caps every running VM's console (§11.3)", ctx do
      vmctl(ctx, fn _ -> %{"ok" => true} end)
      vm_id = CrewProtocol.uuid7()
      dir = Path.join([ctx.data, "jail", "firecracker", vm_id])
      File.mkdir_p!(dir)
      console = Path.join(dir, "console.log")
      File.write!(console, :binary.copy("x", 9 * 1024 * 1024))
      pid = start_supervised!({Monitor, interval: :manual})
      Monitor.tick(pid)
      assert File.stat!(console).size == 8 * 1024 * 1024
    end
  end

  describe "box.restart (§12.1)" do
    test "goes through crew-vmctl reboot, which checks the boot id", ctx do
      boot = CrewProtocol.uuid()

      vmctl(ctx, fn
        %{"verb" => "reboot", "boot_id" => ^boot, "force" => false} ->
          %{"ok" => false, "error" => "busy", "detail" => "2 VMs are running"}

        %{"verb" => "reboot", "boot_id" => ^boot, "force" => true} ->
          %{"ok" => true}

        %{"verb" => "reboot"} ->
          %{"ok" => true, "already" => true}
      end)

      assert {:error, "busy", "2 VMs are running"} = Firecracker.reboot(boot, false)
      assert :ok = Firecracker.reboot(boot, true)
      assert {:ok, %{already: true}} = Firecracker.reboot(CrewProtocol.uuid(), false)

      {:ok, cmd} = CrewProtocol.Command.new("box.restart", %{"boot_id" => boot, "force" => true})
      assert :ok = CrewAgent.Handler.handle(cmd)
    end

    test "isn't offered by the other drivers" do
      {:ok, cmd} = CrewProtocol.Command.new("box.restart", %{"boot_id" => CrewProtocol.uuid()})
      Config.put(%{Config.get() | driver: "null"})
      assert {:error, "unsupported", _} = CrewAgent.Handler.handle(cmd)
    end
  end

  test "the console of a running VM is in the jail, and in vms/ once it's gone", ctx do
    vm_id = CrewProtocol.uuid7()

    assert Firecracker.console_log(vm_id) ==
             Path.join([ctx.data, "jail", "firecracker", vm_id, "console.log"])

    File.mkdir_p!(Config.vm_dir(ctx.config, vm_id))
    File.write!(Path.join(Config.vm_dir(ctx.config, vm_id), "console.log"), "")

    assert Firecracker.console_log(vm_id) ==
             Path.join([ctx.data, "vms", vm_id, "console.log"])
  end
end
