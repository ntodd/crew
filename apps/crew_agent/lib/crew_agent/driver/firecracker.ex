defmodule CrewAgent.Driver.Firecracker do
  @moduledoc """
  The Linux driver (§11.3): each job VM is Firecracker under jailer, in a
  transient systemd unit `crew-vm-<vm_id>`, so it outlives the agent
  (§10.7). The agent runs as `_crewagent` and holds no root powers:
  everything that needs root goes through crew-vmctl's socket
  (`native/crew-vmctl/README.md`, the contract this follows).

  What the agent does itself:
  - writes `vms/<vm_id>/fc.json` in Firecracker's format, which crew-vmctl
    checks against `vm.json` and rewrites into the jail;
  - reads the unit's cgroup for `alive?/1` and `stats/1`;
  - caps the console in the jail (`CrewAgent.Driver.Firecracker.Monitor`);
  - checks §11.3's requirements, reported as features, and
    `firewall_ok` from `crew-vmctl nft-verify`.
  """
  @behaviour CrewAgent.Driver

  alias CrewAgent.{Config, HostMetrics, Images, SafeFS}
  alias CrewAgent.Driver.Firecracker.{Monitor, Vmctl}

  # §8.3: Firecracker's own memory, per VM, counted in allocation.
  @overhead_mib 64
  @max_vcpus 32
  @min_systemd 252

  # -- crew-vmctl ------------------------------------------------------------

  @doc false
  def vmctl(req), do: Vmctl.request(Config.get().vmctl_socket, req)

  defp vmctl_ok(req) do
    case vmctl(req) do
      {:ok, resp} -> {:ok, resp}
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
    end
  end

  # -- capabilities (§8.3, §11.3) ------------------------------------------------

  @impl true
  def capabilities do
    config = Config.get()
    vcpus = cpus(config)
    memory = HostMetrics.linux_memory(read(Path.join(config.proc, "meminfo"))).total
    {area, _free} = HostMetrics.disk(Config.vms_dir(config))
    info = info()
    {virtualized, vendor} = virtualization()

    {:ok,
     %{
       driver: "firecracker",
       driver_version: driver_version(info),
       guest_arch: guest_arch(),
       vcpus: vcpus,
       memory_mib: max(memory, 1),
       vm_area_mib: area,
       max_vcpus_per_vm: min(vcpus, @max_vcpus),
       # What's left after placement's default reserve (§8.3).
       max_memory_mib_per_vm: max(memory - 2048 - div(memory, 20), 1),
       vmm_overhead_mib: @overhead_mib,
       features: features(config, info),
       virtualized: virtualized,
       hypervisor_vendor: vendor,
       firewall_ok: firewall_ok?()
     }}
  end

  defp info do
    case vmctl(%{"verb" => "info"}) do
      {:ok, %{"info" => info}} -> info
      _ -> %{}
    end
  end

  defp driver_version(%{"firecracker" => fc, "vmctl" => v}) when fc != "",
    do: String.slice("firecracker #{fc}, crew-vmctl #{v}", 0, 64)

  defp driver_version(_), do: "unknown"

  defp firewall_ok? do
    case Monitor.firewall_ok?() do
      nil -> Monitor.verify()
      ok -> ok
    end
  end

  # §11.3's requirements, as feature codes, plus what the driver offers.
  defp features(config, info) do
    [
      {"kvm", File.exists?(Path.join(config.devfs, "kvm"))},
      {"tun", File.exists?(Path.join(config.devfs, "net/tun"))},
      {"cgroup2", File.exists?(Path.join(config.sys, "fs/cgroup/cgroup.controllers"))},
      {"xfs_reflink", xfs_reflink?(config)},
      {"systemd", (info["systemd"] || 0) >= @min_systemd},
      {"rate_limits", true}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # XFS, and a reflink copy that works, in the data directory (§12.5).
  # Checked once per boot of the agent: neither changes under it.
  defp xfs_reflink?(config) do
    key = {__MODULE__, :xfs_reflink, config.data_dir}

    case :persistent_term.get(key, nil) do
      nil ->
        ok = xfs?(config.data_dir) and reflink?(Config.images_dir(config))
        :persistent_term.put(key, ok)
        ok

      ok ->
        ok
    end
  end

  defp xfs?(dir) do
    match?({"xfs\n", 0}, System.cmd("stat", ["-f", "-c", "%T", dir], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp reflink?(dir) do
    src = Path.join(dir, ".reflink-check-#{System.unique_integer([:positive])}")
    dst = src <> ".copy"

    try do
      File.mkdir_p!(dir)
      File.write!(src, "crew")
      match?({_, 0}, System.cmd("cp", ["--reflink=always", src, dst], stderr_to_stdout: true))
    rescue
      _ -> false
    after
      File.rm(src)
      File.rm(dst)
    end
  end

  defp cpus(config) do
    case config.sys |> Path.join("devices/system/cpu/online") |> read() |> String.trim() do
      "" -> System.schedulers_online()
      online -> online |> String.split(",") |> Enum.map(&range_size/1) |> Enum.sum()
    end
  end

  defp range_size(part) do
    case String.split(part, "-") do
      [a, b] -> String.to_integer(b) - String.to_integer(a) + 1
      [_] -> 1
    end
  end

  defp guest_arch do
    if :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64"),
      do: "arm64",
      else: "x64"
  end

  defp virtualization do
    case System.cmd("systemd-detect-virt", ["--vm"], stderr_to_stdout: true) do
      {out, 0} -> {true, out |> String.trim() |> String.slice(0, 64)}
      _ -> {false, nil}
    end
  rescue
    _ -> {false, nil}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  # -- images ---------------------------------------------------------------------

  @impl true
  def prepare_image(image), do: {:ok, image}

  # -- VMs ------------------------------------------------------------------------------

  @impl true
  def start(spec) do
    config = Config.get()
    lease = spec.net

    # The tap and the pair first: without the pair the VM's traffic is
    # dropped, so the start is aborted (§11.2).
    with {:ok, _} <- vmctl_ok(%{"verb" => "tap-add", "lease_index" => lease.index}),
         {:ok, _} <- vmctl_ok(%{"verb" => "pair-add", "lease_index" => lease.index}),
         :ok <-
           SafeFS.write_atomic(
             Path.join(spec.vm_dir, "fc.json"),
             Jason.encode!(fc_json(config, spec)),
             0o640
           ),
         {:ok, _} <- vmctl_ok(%{"verb" => "start", "vm_id" => spec.vm_id}) do
      :ok
    end
  end

  @doc """
  `vms/<vm_id>/fc.json` (§11.3): Firecracker's own format, with host
  paths and the size's rate limiters. crew-vmctl checks every value and
  adds the logger and metrics.
  """
  def fc_json(config, spec) do
    lease = spec.net

    %{
      "boot-source" => %{
        "kernel_image_path" => Images.kernel(config, spec.image.id),
        "boot_args" => spec.boot_args
      },
      "drives" => [
        %{
          "drive_id" => "rootfs",
          "path_on_host" => spec.clone,
          "is_root_device" => true,
          "is_read_only" => false
        }
        |> put_limiter("rate_limiter", disk_limiter(spec.limits))
      ],
      "machine-config" => %{
        "vcpu_count" => spec.vcpus,
        "mem_size_mib" => spec.memory_mib,
        "smt" => false
      },
      "network-interfaces" => [
        %{
          "iface_id" => "eth0",
          "host_dev_name" => "crewt#{lease.index}",
          "guest_mac" => lease.mac
        }
        |> put_limiter("rx_rate_limiter", net_limiter(spec.limits))
        |> put_limiter("tx_rate_limiter", net_limiter(spec.limits))
      ],
      "entropy" => %{}
    }
  end

  # Limits (§7.1) are per second: a bucket holds a second's worth and
  # refills in a second. Bandwidths are in Mbit/s.
  defp bucket(nil, _), do: nil
  defp bucket(n, per_unit), do: %{"size" => n * per_unit, "refill_time" => 1000}

  defp limiter(buckets) do
    case buckets |> Enum.reject(fn {_, b} -> is_nil(b) end) |> Map.new() do
      empty when map_size(empty) == 0 -> nil
      l -> l
    end
  end

  defp disk_limiter(limits) do
    limiter(%{
      "bandwidth" => bucket(limit(limits, :disk_bandwidth_mbps), 125_000),
      "ops" => bucket(limit(limits, :disk_iops), 1)
    })
  end

  defp net_limiter(limits),
    do: limiter(%{"bandwidth" => bucket(limit(limits, :net_bandwidth_mbps), 125_000)})

  defp limit(limits, key),
    do: Map.get(limits || %{}, key) || Map.get(limits || %{}, to_string(key))

  defp put_limiter(map, _key, nil), do: map
  defp put_limiter(map, key, limiter), do: Map.put(map, key, limiter)

  @impl true
  def stop(vm_id, force) do
    case vmctl(%{"verb" => "stop", "vm_id" => vm_id, "force" => force}) do
      {:ok, _} -> :ok
      # Nothing to stop.
      {:error, "not_found", _} -> :ok
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
    end
  end

  # The unit's cgroup is there from its start until systemd is done with
  # it: past the VMM's exit (the cgroup is empty for a moment), through
  # ExecStopPost, which writes the exit record. So once it's gone, the
  # record is there.
  @impl true
  def alive?(vm_id), do: File.dir?(cgroup(vm_id))

  defp cgroup(vm_id) do
    Path.join([Config.get().sys, "fs/cgroup/system.slice", "crew-vm-#{vm_id}.service"])
  end

  @impl true
  def list do
    case vmctl(%{"verb" => "list"}) do
      {:ok, resp} -> {:ok, Map.get(resp, "vms", [])}
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
    end
  end

  # The host's view (§11.1): the unit's CPU since the last sample (100 is
  # one CPU) and its memory, the guest's RAM included.
  @impl true
  def stats(vm_id) do
    dir = cgroup(vm_id)

    with {:ok, cpu} <- File.read(Path.join(dir, "cpu.stat")),
         [_, usec] <- Regex.run(~r/^usage_usec (\d+)$/m, cpu),
         {:ok, mem} <- File.read(Path.join(dir, "memory.current")),
         {bytes, _} <- Integer.parse(mem) do
      usec = String.to_integer(usec)
      now = System.monotonic_time(:microsecond)
      {:ok, %{cpu_pct: cpu_pct(vm_id, usec, now), rss_mib: div(bytes, 1024 * 1024)}}
    else
      _ -> {:error, :not_running}
    end
  end

  defp cpu_pct(vm_id, usec, now) do
    table = Monitor.stats_table()

    if :ets.whereis(table) == :undefined do
      0.0
    else
      previous = :ets.lookup(table, vm_id)
      :ets.insert(table, {vm_id, usec, now})

      case previous do
        [{_, u0, t0}] when now > t0 and usec >= u0 ->
          Float.round((usec - u0) / (now - t0) * 100, 1)

        _ ->
          0.0
      end
    end
  end

  @impl true
  def cleanup(vm_id) do
    config = Config.get()
    dir = Config.vm_dir(config, vm_id)
    _ = vmctl(%{"verb" => "cleanup", "vm_id" => vm_id})

    # The lease's pair and tap, in case the start failed before
    # crew-vmctl recorded it (cleanup does those it recorded).
    with {:ok, body} <- File.read(Path.join(dir, "vm.json")),
         {:ok, %{"lease_index" => index}} when is_integer(index) <- Jason.decode(body) do
      _ = vmctl(%{"verb" => "pair-del", "lease_index" => index})
      _ = vmctl(%{"verb" => "tap-del", "lease_index" => index})
    end

    if :ets.whereis(Monitor.stats_table()) != :undefined,
      do: :ets.delete(Monitor.stats_table(), vm_id)

    # fc.json has the guest's token in its boot args.
    File.rm(Path.join(dir, "fc.json"))
    :ok
  end

  # crew-vmctl's exit record (written by the unit's ExecStopPost), in the
  # protocol's words where it knows better than the agent: a deadline
  # kill while the agent was down, or a kill.
  @impl true
  def exit_status(vm_id) do
    case vmctl(%{"verb" => "status", "vm_id" => vm_id}) do
      {:ok, %{"vm" => %{"exited" => %{"code" => code} = record}}} when is_integer(code) ->
        {:ok, %{code: code, reason: reason(record)}}

      _ ->
        :unknown
    end
  end

  defp reason(%{"service_result" => "timeout"}), do: "killed_deadline"

  defp reason(%{"service_result" => "signal", "exit_status" => "KILL"}), do: "killed_stop"

  # `systemctl stop`: SIGTERM, and systemd counts that as clean.
  defp reason(%{"service_result" => "success", "exit_code" => "killed"}), do: "killed_stop"

  defp reason(_), do: nil

  @doc """
  `box.restart` (§12.1): crew-vmctl checks the boot id, refuses while a
  VM unit is live unless `force`, and reboots 5 s later.
  """
  def reboot(boot_id, force) do
    case vmctl(%{"verb" => "reboot", "boot_id" => boot_id, "force" => force}) do
      {:ok, %{"already" => true}} -> {:ok, %{already: true}}
      {:ok, _} -> :ok
      {:error, code, detail} -> {:error, code, detail}
    end
  end

  @doc """
  The VM's console: in the jail while it runs, in `vms/<vm_id>/` once
  crew-vmctl's cleanup has moved it there.
  """
  def console_log(vm_id) do
    config = Config.get()
    moved = Path.join(Config.vm_dir(config, vm_id), "console.log")

    if File.exists?(moved),
      do: moved,
      else: Path.join([config.data_dir, "jail", "firecracker", vm_id, "console.log"])
  end
end
