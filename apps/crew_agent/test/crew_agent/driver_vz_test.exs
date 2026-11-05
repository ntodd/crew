defmodule CrewAgent.Driver.VZTest do
  @moduledoc "The vz driver against a fake crew-vzd (the real one runs in native/'s integration suite)."
  use ExUnit.Case, async: false

  alias CrewAgent.{Config, FakeVzd}
  alias CrewAgent.Driver.VZ

  setup do
    base = Config.get()
    # Unix socket paths are short on macOS.
    tmp = if match?({:unix, :darwin}, :os.type()), do: "/private/tmp", else: "/tmp"
    dir = "#{tmp}/cvz#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    sock = Path.join(dir, "vzd.sock")

    config = %{
      base
      | driver: "vz",
        data_dir: dir,
        vzd_socket: sock,
        vz_dns_fallback: "1.1.1.1",
        extra_blocked: ["203.0.113.7/32"]
    }

    Config.put(config)

    on_exit(fn ->
      Config.put(base)
      File.rm_rf!(dir)
    end)

    %{config: config, dir: dir, sock: sock}
  end

  defp vzd(%{sock: sock}, answer \\ fn _ -> %{"ok" => true} end) do
    test = self()
    start_supervised!({FakeVzd, {sock, answer, test}})
    :ok
  end

  defp spec(config) do
    vm_id = CrewProtocol.uuid7()
    vm_dir = Config.vm_dir(config, vm_id)
    File.mkdir_p!(vm_dir)
    clone = Path.join(vm_dir, "rootfs.ext4")
    File.write!(clone, "")
    image_id = CrewProtocol.uuid7()

    %{
      vm_id: vm_id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      limits: %{},
      image: %{id: image_id},
      clone: clone,
      boot_args: "console=hvc0 crew.vm=#{vm_id}",
      net: CrewAgent.Net.lease(3),
      guest_socket: Path.join(vm_dir, "guest.sock"),
      guest_token: "t",
      guest_api: "http://10.199.0.1:7777",
      deadline: System.os_time(:second) + 3600,
      console_log: Path.join(vm_dir, "console.log"),
      vm_dir: vm_dir
    }
  end

  test "start writes vz.json the way crew-vz reads it, then asks crew-vzd with the deadline",
       ctx do
    vzd(ctx)
    spec = spec(ctx.config)
    assert :ok = VZ.start(spec)

    assert_received {:vzd, %{"op" => "start", "vm_id" => vm_id, "deadline" => deadline}}
    assert vm_id == spec.vm_id and deadline == spec.deadline

    cfg = spec.vm_dir |> Path.join("vz.json") |> File.read!() |> Jason.decode!()
    lease = spec.net
    {site4, cfg} = Map.pop!(cfg, "site4")

    # site4: this Mac's own subnets, and the admin's list (§14.2).
    {:ok, ifaddrs} = :inet.getifaddrs()

    assert site4 ==
             CrewAgent.Site.site4(
               ctx.config,
               CrewAgent.Site.connected(ifaddrs, ctx.config.vm_net),
               nil
             )

    assert "203.0.113.7/32" in site4

    assert cfg == %{
             "vm_id" => spec.vm_id,
             "vcpus" => 4,
             "memory_mib" => 8192,
             "kernel" => Path.join([ctx.dir, "images", spec.image.id, "kernel"]),
             "cmdline" => spec.boot_args,
             "disk" => spec.clone,
             "console_log" => spec.console_log,
             "guest_socket" => spec.guest_socket,
             "ctl_socket" => Path.join(spec.vm_dir, "ctl.sock"),
             "exited_path" => Path.join(spec.vm_dir, "vz-exited.json"),
             "lease" => %{
               "gateway" => lease.gateway <> "/30",
               "guest" => lease.guest <> "/30",
               "mac" => lease.mac
             },
             "service_ip" => "10.199.0.1",
             "cache_addr" => "",
             "dns_fallback" => "1.1.1.1",
             "max_conns" => 1024,
             "mtu" => 1500
           }

    # The helper (_crewvm) writes in the VM's directory.
    assert File.stat!(spec.vm_dir).mode |> Bitwise.band(0o777) == 0o770
    assert File.stat!(spec.clone).mode |> Bitwise.band(0o777) == 0o660
  end

  test "socket paths too long for macOS are refused before crew-vzd sees them", ctx do
    vzd(ctx)
    long = %{ctx.config | data_dir: Path.join(Path.dirname(ctx.dir), String.duplicate("d", 60))}
    Config.put(long)
    spec = spec(long)
    assert {:error, "the VM's socket paths are too long" <> _} = VZ.start(spec)
    refute_received {:vzd, _}
    File.rm_rf!(long.data_dir)
  end

  test "production paths fit" do
    path = "/Library/Application Support/Crew/vms/#{CrewProtocol.uuid7()}/guest.sock"
    assert byte_size(path) <= 103
  end

  test "the cache VM's address is its lease in vmnet's DHCP leases, by its MAC", ctx do
    vzd(ctx)
    leases = Path.join(ctx.dir, "dhcpd_leases")

    File.write!(
      leases,
      "{\n\tip_address=192.168.64.3\n\thw_address=1,52:54:0:a:b:c\n\tlease=0x1\n}\n"
    )

    Config.put(%{
      ctx.config
      | vz_cache: %{ctx.config.vz_cache | mac: "52:54:00:0a:0b:0c", leases: leases}
    })

    spec = spec(ctx.config)
    assert :ok = VZ.start(spec)
    cfg = spec.vm_dir |> Path.join("vz.json") |> File.read!() |> Jason.decode!()
    assert cfg["cache_addr"] == "192.168.64.3"
  end

  test "a lease that isn't an address is ignored", ctx do
    vzd(ctx)
    leases = Path.join(ctx.dir, "dhcpd_leases")

    File.write!(
      leases,
      "{\n\tip_address=192.168.64.3:80; rm\n\thw_address=1,52:54:0:a:b:c\n\tlease=0x1\n}\n"
    )

    Config.put(%{
      ctx.config
      | vz_cache: %{ctx.config.vz_cache | mac: "52:54:00:0a:0b:0c", leases: leases}
    })

    spec = spec(ctx.config)
    assert :ok = VZ.start(spec)

    assert (spec.vm_dir |> Path.join("vz.json") |> File.read!() |> Jason.decode!())["cache_addr"] ==
             ""
  end

  test "a refused start is an error with crew-vzd's code", ctx do
    vzd(ctx, fn _ ->
      %{"ok" => false, "error" => "invalid_config", "detail" => "kernel: not an arm64 Image"}
    end)

    assert {:error, "invalid_config: kernel: not an arm64 Image"} = VZ.start(spec(ctx.config))
  end

  test "stop: graceful or forced; a VM that's already gone is fine", ctx do
    vzd(ctx, fn
      %{"vm_id" => "gone"} -> %{"ok" => false, "error" => "not_running", "detail" => ""}
      _ -> %{"ok" => true, "vm" => %{"state" => "exited"}}
    end)

    assert :ok = VZ.stop("a", false)
    assert_received {:vzd, %{"op" => "stop", "vm_id" => "a", "force" => false}}
    assert :ok = VZ.stop("a", true)
    assert_received {:vzd, %{"op" => "stop", "force" => true}}
    assert :ok = VZ.stop("gone", true)
  end

  test "alive? and list follow crew-vzd", ctx do
    vzd(ctx, fn
      %{"op" => "list"} -> %{"ok" => true, "vms" => [%{"vm_id" => "a", "state" => "running"}]}
      %{"op" => "status", "vm_id" => "a"} -> %{"ok" => true, "vm" => %{"state" => "running"}}
      %{"op" => "status", "vm_id" => "b"} -> %{"ok" => true, "vm" => %{"state" => "exited"}}
      %{"op" => "status"} -> %{"ok" => false, "error" => "not_found", "detail" => ""}
    end)

    assert VZ.alive?("a")
    refute VZ.alive?("b")
    refute VZ.alive?("c")
    assert {:ok, ["a"]} = VZ.list()
  end

  test "with crew-vzd down, a VM launched with no exit record counts as alive", ctx do
    spec = spec(ctx.config)
    refute VZ.alive?(spec.vm_id)
    File.write!(Path.join(spec.vm_dir, "vz.pid"), "4242")
    assert VZ.alive?(spec.vm_id)
    File.write!(Path.join(spec.vm_dir, "vz-exited.json"), ~s({"code":0,"reason":"guest_stopped"}))
    refute VZ.alive?(spec.vm_id)
  end

  test "the helper's exit record, in the protocol's words", ctx do
    spec = spec(ctx.config)
    assert VZ.exit_status(spec.vm_id) == :unknown

    for {reason, code, expected} <- [
          {"guest_stopped", 0, nil},
          {"deadline", 3, "killed_deadline"},
          {"killed", 2, "killed_stop"},
          {"error", 1, "crashed"},
          {"helper_died", 1, "crashed"}
        ] do
      File.write!(
        Path.join(spec.vm_dir, "vz-exited.json"),
        Jason.encode!(%{code: code, reason: reason, at: "x"})
      )

      assert {:ok, %{code: ^code, reason: ^expected}} = VZ.exit_status(spec.vm_id)
    end
  end

  test "cleanup removes the disk but keeps vz.pid, so the VM is never relaunched", ctx do
    vzd(ctx, fn _ -> %{"ok" => false, "error" => "not_found", "detail" => ""} end)
    spec = spec(ctx.config)
    File.write!(Path.join(spec.vm_dir, "vz.pid"), "1")
    File.write!(Path.join(spec.vm_dir, "vz-exited.json"), ~s({"code":0}))
    assert :ok = VZ.cleanup(spec.vm_id)
    refute File.exists?(spec.clone)
    assert File.exists?(Path.join(spec.vm_dir, "vz.pid"))
  end

  # sysctl, pmset and df as macOS has them.
  @tag :darwin
  test "capabilities follow §11.4", ctx do
    vzd(ctx, fn _ -> %{"ok" => true} end)
    {:ok, caps} = VZ.capabilities()
    {cores, 0} = System.cmd("sysctl", ["-n", "hw.physicalcpu"])
    {bytes, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
    mem = div(String.to_integer(String.trim(bytes)), 1024 * 1024)

    assert caps.driver == "vz"
    assert caps.guest_arch == "arm64"
    assert caps.vcpus == String.to_integer(String.trim(cores)) - 2
    assert caps.memory_mib == mem - 8192
    assert caps.max_vcpus_per_vm == caps.vcpus
    assert caps.vmm_overhead_mib == 128
    assert caps.vm_area_mib <= 400 * 1024
    assert caps.firewall_ok
    assert {:ok, _} = CrewProtocol.Event.new("box.capabilities", caps)
  end

  @tag :darwin
  test "with crew-vzd down, the box doesn't claim its network boundary", _ctx do
    {:ok, caps} = VZ.capabilities()
    refute caps.firewall_ok
  end
end
