defmodule CrewAgent.Driver.Null do
  @moduledoc """
  The dev and test driver (§11.5): a "VM" is a local OS process running
  crew-guest (or the fake guest in `priv/null/fake-guest.sh`) against the
  guest API on 127.0.0.1. It makes the control plane, scheduler,
  protocol and UI buildable without a hypervisor.

  Compiled only in dev and test; a `:prod` release refuses it, and the
  control plane refuses agents that report it unless `CREW_DEV=1`.

  Unlike the real drivers, its VMs are the agent's children: they don't
  survive an agent restart.
  """
  @behaviour CrewAgent.Driver

  use GenServer

  alias CrewAgent.Config

  @registry CrewAgent.Registry

  # -- the behaviour ------------------------------------------------------------

  @impl CrewAgent.Driver
  def capabilities do
    {:ok,
     %{
       driver: "null",
       driver_version: "0.1.0",
       guest_arch: if(arm?(), do: "arm64", else: "x64"),
       vcpus: Application.get_env(:crew_agent, :null_vcpus, 16),
       memory_mib: Application.get_env(:crew_agent, :null_memory_mib, 65_536),
       vm_area_mib: 409_600,
       max_vcpus_per_vm: 32,
       max_memory_mib_per_vm: 65_536,
       vmm_overhead_mib: 64,
       features: ["graceful_stop"],
       virtualized: false,
       hypervisor_vendor: nil,
       firewall_ok: true
     }}
  end

  defp arm?, do: :erlang.system_info(:system_architecture) |> to_string() |> String.contains?(["aarch64", "arm"])

  @impl CrewAgent.Driver
  def prepare_image(image), do: {:ok, image}

  @impl CrewAgent.Driver
  def start(spec) do
    case DynamicSupervisor.start_child(CrewAgent.Driver.Null.Supervisor, {__MODULE__, spec}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> {:error, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl CrewAgent.Driver
  def stop(vm_id, force) do
    case lookup(vm_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:stop, force})
    end
  end

  @impl CrewAgent.Driver
  def alive?(vm_id), do: lookup(vm_id) != nil

  @impl CrewAgent.Driver
  def list do
    {:ok, Registry.select(@registry, [{{{:null_vm, :"$1"}, :_, :_}, [], [:"$1"]}])}
  end

  @impl CrewAgent.Driver
  def stats(vm_id) do
    if alive?(vm_id), do: {:ok, %{cpu_pct: 0.0, rss_mib: 0}}, else: {:error, :not_running}
  end

  @impl CrewAgent.Driver
  def cleanup(vm_id) do
    case lookup(vm_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:stop, true})
    end

    :ok
  end

  @impl CrewAgent.Driver
  def exit_status(vm_id) do
    path = Path.join(Config.vm_dir(Config.get(), vm_id), "exit_code")

    case File.read(path) do
      {:ok, body} ->
        [code | rest] = String.split(String.trim(body), " ")
        {:ok, %{code: String.to_integer(code), reason: List.first(rest)}}

      _ ->
        :unknown
    end
  end

  defp lookup(vm_id) do
    case Registry.lookup(@registry, {:null_vm, vm_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # -- one process per "VM" ------------------------------------------------------

  def child_spec(spec),
    do: %{id: {__MODULE__, spec.vm_id}, start: {__MODULE__, :start_link, [spec]}, restart: :temporary}

  def start_link(spec),
    do: GenServer.start_link(__MODULE__, spec, name: {:via, Registry, {@registry, {:null_vm, spec.vm_id}}})

  @impl GenServer
  def init(spec) do
    config = Config.get()
    # Dev and test only: the token is the guest's own (it's on a real
    # VM's kernel command line), kept here so tests can act as the guest.
    File.write!(Path.join(spec.vm_dir, "null-token"), spec.guest_token)
    script = config.null_guest_cmd || Application.app_dir(:crew_agent, "priv/null/fake-guest.sh")

    env =
      [
        {"CREW_GUEST_API", spec.guest_api},
        {"CREW_GUEST_TOKEN", spec.guest_token},
        {"CREW_GUEST_VM", spec.vm_id},
        {"CREW_GUEST_MODE", "local"},
        {"CREW_GUEST_RUNNER_DIR", Path.join(spec.vm_dir, "runner")}
      ] ++ Application.get_env(:crew_agent, :null_env, [])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", "exec " <> script],
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(to_string(v))} end),
        cd: spec.vm_dir
      ])

    {:ok, %{spec: spec, port: port, os_pid: Port.info(port)[:os_pid], console: spec.console_log, reason: nil}}
  end

  @impl GenServer
  def handle_call({:stop, force}, _from, state) do
    signal = if force, do: "-KILL", else: "-TERM"
    pid = to_string(state.os_pid)
    # The guest's own children (sleep, curl) go too, or they'd hold its
    # output open after it's gone.
    System.cmd("pkill", [signal, "-P", pid], stderr_to_stdout: true)
    System.cmd("kill", [signal, pid], stderr_to_stdout: true)
    {:reply, :ok, %{state | reason: if(force, do: "killed", else: "stopped")}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    File.write(state.console, data, [:append])
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    File.write!(Path.join(state.spec.vm_dir, "exit_code"), "#{code} #{state.reason || "exited"}")
    {:stop, :normal, state}
  end
end
