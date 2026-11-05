defmodule CrewAgent.Driver.VZ do
  @moduledoc """
  The macOS driver (§11.4): job VMs under Virtualization.framework,
  through crew-vzd (`native/crew-vz`). The agent writes each VM's
  `vz.json` and asks crew-vzd to start it; crew-vzd runs one `crew-vz
  run` helper per VM, which owns the VM, its userspace network (§14.3)
  and its exit record. Helpers outlive the agent and crew-vzd.

  Files in `vms/<vm_id>/` besides the agent's own: `vz.json`, `vz.pid`
  (the helper's, never removed: a VM is launched once), `vz-exited.json`
  (the helper's exit record), `ctl.sock`, `console.log` and `vz.log`.

  `firewall_ok` is crew-vzd answering: the isolation boundary is the
  helper's netstack, which crew-vz's own tests check against a real
  guest, not a host firewall.
  """
  @behaviour CrewAgent.Driver

  alias CrewAgent.{Config, Images}
  alias CrewAgent.Driver.VZ.Daemon

  @overhead_mib 128
  @alive ~w(starting running stopping unresponsive)

  # -- capabilities (§11.4) --------------------------------------------------------

  @impl true
  def capabilities do
    config = Config.get()

    with {:ok, cores} <- sysctl_int("hw.physicalcpu"),
         {:ok, bytes} <- sysctl_int("hw.memsize") do
      mem_mib = div(bytes, 1024 * 1024)
      memory = max(mem_mib - config.vz_host_reserve_mib - host_vm_memory(config), 0)
      vcpus = max(cores - config.vz_host_reserve_vcpus, 1)
      virtualized = sysctl_int("kern.hv_vmm_present") == {:ok, 1}

      {:ok,
       %{
         driver: "vz",
         driver_version: driver_version(),
         guest_arch: "arm64",
         vcpus: vcpus,
         memory_mib: memory,
         vm_area_mib: vm_area_mib(config),
         max_vcpus_per_vm: vcpus,
         # crew-vzd's default ceiling: the Mac's memory less 2 GiB.
         max_memory_mib_per_vm: min(memory, mem_mib - 2048),
         vmm_overhead_mib: @overhead_mib,
         features: ["graceful_stop"],
         virtualized: virtualized,
         hypervisor_vendor: if(virtualized, do: "apple"),
         # The boundary is crew-vzd's helpers; with a cache VM, guests
         # also need it for DNS, so the box takes no jobs until it answers
         # (after a Mac reboot the agent can be up first, §15.6).
         firewall_ok:
           match?({:ok, _}, daemon(%{"op" => "list"})) and CrewAgent.CacheVM.ready?(config),
         sleep_disabled: sleep_disabled?()
       }}
    end
  end

  defp sysctl_int(name) do
    case System.cmd("sysctl", ["-n", name], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:sysctl, name, out}}
        end

      {out, _} ->
        {:error, {:sysctl, name, out}}
    end
  end

  # vfkit host VMs (§12.3) on this Mac take their memory off the top.
  defp host_vm_memory(config) do
    Path.join([config.data_dir, "hostvm", "*.conf"])
    |> Path.wildcard()
    |> Enum.map(fn path ->
      with {:ok, body} <- File.read(path),
           [_, mib] <- Regex.run(~r/^memory_mib\s*=\s*(\d+)/m, body),
           do: String.to_integer(mib),
           else: (_ -> 0)
    end)
    |> Enum.sum()
  end

  # CREW_VZ_VM_AREA_GIB, capped at 80% of the volume's free space.
  defp vm_area_mib(config) do
    wanted = config.vz_vm_area_gib * 1024

    case free_mib(config.data_dir) do
      {:ok, free} -> min(wanted, floor(free * 0.8))
      :error -> wanted
    end
  end

  defp free_mib(dir) do
    with {out, 0} <- System.cmd("df", ["-k", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, avail | _] <- String.split(line),
         {kib, ""} <- Integer.parse(avail) do
      {:ok, div(kib, 1024)}
    else
      _ -> :error
    end
  end

  defp sleep_disabled? do
    case System.cmd("pmset", ["-g"], stderr_to_stdout: true) do
      {out, 0} -> Regex.match?(~r/^\s*sleep\s+0\b/m, out)
      _ -> nil
    end
  end

  defp driver_version do
    case System.cmd(binary(), ["version"], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.trim() |> String.replace_prefix("crew-vz ", "") |> String.slice(0, 64)

      _ ->
        "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp binary, do: Application.get_env(:crew_agent, :crew_vz_bin, "crew-vz")

  # -- images ---------------------------------------------------------------------------

  @impl true
  def prepare_image(image), do: {:ok, image}

  # -- VMs --------------------------------------------------------------------------------

  @impl true
  def start(spec) do
    config = Config.get()

    with :ok <- socket_paths_fit(spec),
         :ok <- permissions(spec),
         :ok <- write_config(config, spec),
         {:ok, _} <-
           daemon(%{"op" => "start", "vm_id" => spec.vm_id, "deadline" => spec.deadline}) do
      :ok
    else
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # macOS caps a Unix socket path at 104 bytes, NUL included.
  @max_socket_path 103
  defp socket_paths_fit(spec) do
    longest =
      [spec.guest_socket, Path.join(spec.vm_dir, "ctl.sock")]
      |> Enum.map(&byte_size/1)
      |> Enum.max()

    if longest <= @max_socket_path,
      do: :ok,
      else:
        {:error,
         "the VM's socket paths are too long for macOS (#{longest} bytes, at most #{@max_socket_path}); use a shorter CREW_DATA_DIR"}
  end

  # The helper runs as `_crewvm` and writes in the VM's directory, so the
  # directory and the clone are group-writable (crew-vz README).
  defp permissions(spec) do
    with :ok <- File.chmod(spec.vm_dir, 0o770), do: File.chmod(spec.clone, 0o660)
  end

  @doc false
  def vz_json(config, spec) do
    dir = spec.vm_dir
    lease = spec.net

    %{
      "vm_id" => spec.vm_id,
      "vcpus" => spec.vcpus,
      "memory_mib" => spec.memory_mib,
      "kernel" => Images.kernel(config, spec.image.id),
      "cmdline" => spec.boot_args,
      "disk" => spec.clone,
      "console_log" => spec.console_log,
      "guest_socket" => spec.guest_socket,
      "ctl_socket" => Path.join(dir, "ctl.sock"),
      "exited_path" => Path.join(dir, "vz-exited.json"),
      "lease" => %{
        "gateway" => lease.gateway <> "/30",
        "guest" => lease.guest <> "/30",
        "mac" => lease.mac
      },
      "service_ip" => config.service_ip,
      "cache_addr" => cache_addr(config),
      "dns_fallback" => config.vz_dns_fallback || "",
      "site4" => CrewAgent.Site.current(config),
      # Each connection can hold up to 2 MiB in the helper, outside the
      # guest's memory (native/crew-vz/netstack): 1024 bounds it at 2 GiB.
      "max_conns" => config.vz_max_conns,
      "mtu" => config.vz_mtu
    }
  end

  # The cache VM's address (§15.6), or "" for none: crew-vz then
  # answers the guest's 10.199.0.1 itself, with CREW_VZ_DNS_FALLBACK.
  defp cache_addr(config), do: CrewAgent.CacheVM.address(config) || ""

  defp write_config(config, spec) do
    body = Jason.encode!(vz_json(config, spec))
    CrewAgent.SafeFS.write_atomic(Path.join(spec.vm_dir, "vz.json"), body, 0o640)
  end

  @impl true
  def stop(vm_id, force) do
    case daemon(%{"op" => "stop", "vm_id" => vm_id, "force" => force}) do
      {:ok, _} -> :ok
      # Nothing to stop.
      {:error, code, _} when code in ["not_found", "not_running", "already_exited"] -> :ok
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
    end
  end

  @impl true
  def alive?(vm_id) do
    case daemon(%{"op" => "status", "vm_id" => vm_id}) do
      {:ok, %{"vm" => %{"state" => state}}} -> state in @alive
      {:error, "not_found", _} -> false
      # crew-vzd down: the helpers aren't. Launched with no exit record
      # means it may well be running.
      {:error, _, _} -> launched_without_record?(vm_id)
    end
  end

  defp launched_without_record?(vm_id) do
    dir = Config.vm_dir(Config.get(), vm_id)
    File.exists?(Path.join(dir, "vz.pid")) and not File.exists?(Path.join(dir, "vz-exited.json"))
  end

  @impl true
  def list do
    case daemon(%{"op" => "list"}) do
      {:ok, resp} -> {:ok, resp |> Map.get("vms", []) |> Enum.map(& &1["vm_id"])}
      {:error, code, detail} -> {:error, "#{code}: #{detail}"}
    end
  end

  @impl true
  def stats(vm_id) do
    with {:ok, %{"vm" => %{"pid" => pid}}} when is_integer(pid) <-
           daemon(%{"op" => "status", "vm_id" => vm_id}),
         {out, 0} <-
           System.cmd("ps", ["-o", "%cpu=,rss=", "-p", to_string(pid)], stderr_to_stdout: true),
         [cpu, rss] <- String.split(out),
         {cpu, _} <- Float.parse(cpu),
         {rss_kib, _} <- Integer.parse(rss) do
      {:ok, %{cpu_pct: cpu, rss_mib: div(rss_kib, 1024)}}
    else
      _ -> {:error, :not_running}
    end
  end

  @impl true
  def cleanup(vm_id) do
    if alive?(vm_id), do: stop(vm_id, true)
    dir = Config.vm_dir(Config.get(), vm_id)
    # The disk goes at once; the rest of the directory goes with the VM's
    # (CrewAgent.VMs.prune/0). vz.pid stays, so the VM is never relaunched.
    for f <- ["rootfs.ext4", "vz.json"], do: File.rm(Path.join(dir, f))
    :ok
  end

  # The helper's exit record, in the protocol's words where it knows
  # better than the agent (a deadline kill while the agent was down).
  @impl true
  def exit_status(vm_id) do
    path = Path.join(Config.vm_dir(Config.get(), vm_id), "vz-exited.json")

    with {:ok, body} <- File.read(path),
         {:ok, %{"code" => code} = record} <- Jason.decode(body) do
      {:ok, %{code: code, reason: reason(record["reason"])}}
    else
      _ -> :unknown
    end
  end

  defp reason("deadline"), do: "killed_deadline"
  defp reason("killed"), do: "killed_stop"
  defp reason("error"), do: "crashed"
  defp reason("helper_died"), do: "crashed"
  defp reason(_), do: nil

  defp daemon(req), do: Daemon.request(socket(), req)

  defp socket do
    config = Config.get()
    config.vzd_socket || Path.join(config.data_dir, "vzd.sock")
  end
end
