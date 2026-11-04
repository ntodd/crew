defmodule CrewAgent.Reporter do
  @moduledoc """
  What the agent tells the control plane without being asked (§10.4):
  `box.capabilities`, `box.inventory` and `box.reboot` on join (and
  capabilities again when they change), and `box.metrics` every 5 s.
  """
  use GenServer

  require Logger

  alias CrewAgent.{Config, Driver, HostMetrics, Images, Outbox, VMs}
  alias CrewProtocol.Event

  @metrics_ms 5_000
  @capabilities_ms 60_000
  @sweep_ms 10 * 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Called on every join."
  def report_now, do: GenServer.cast(__MODULE__, :report_now)
  def report_inventory, do: GenServer.cast(__MODULE__, :inventory)

  @doc """
  Something the capabilities say may have changed (the packet filter's
  verdict): look now rather than at the next minute, and send them if
  they did. A no-op when the reporter isn't running.
  """
  def capabilities_changed, do: GenServer.cast(__MODULE__, :capabilities_changed)

  @impl true
  def init(_) do
    Process.send_after(self(), :metrics, @metrics_ms)
    Process.send_after(self(), :capabilities, @capabilities_ms)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{cpu: nil, capabilities: nil}}
  end

  @impl true
  def handle_cast(:report_now, state) do
    state = send_capabilities(%{state | capabilities: nil})
    send_inventory()
    send_reboot()
    {:noreply, state}
  end

  def handle_cast(:inventory, state) do
    send_inventory()
    {:noreply, state}
  end

  def handle_cast(:capabilities_changed, state), do: {:noreply, send_capabilities(state)}

  @impl true
  def handle_info(:metrics, state) do
    {metrics, cpu} = HostMetrics.sample(Config.get(), state.cpu)
    push("box.metrics", metrics)
    Process.send_after(self(), :metrics, @metrics_ms)
    {:noreply, %{state | cpu: cpu}}
  end

  # Exited VMs' directories go after an hour, so inventories stay small.
  def handle_info(:sweep, state) do
    VMs.sweep_exited()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  def handle_info(:capabilities, state) do
    Process.send_after(self(), :capabilities, @capabilities_ms)
    {:noreply, send_capabilities(state)}
  end

  defp send_capabilities(state) do
    case Driver.impl().capabilities() do
      {:ok, caps} ->
        if caps != state.capabilities, do: push("box.capabilities", caps)
        %{state | capabilities: caps}

      {:error, reason} ->
        Logger.error("the driver can't report its capabilities: #{inspect(reason)}")
        state
    end
  end

  defp send_inventory,
    do: push("box.inventory", %{vms: VMs.inventory(), images: Images.inventory(Config.get())})

  defp send_reboot do
    push("box.reboot", %{
      required: File.exists?("/run/reboot-required"),
      packages: reboot_packages(),
      boot_id: CrewAgent.Boot.id(),
      # Firecracker boxes reboot through crew-vmctl (§12.1).
      can_restart: Config.get().driver == "firecracker",
      os_version: CrewAgent.Boot.os_version()
    })
  end

  defp reboot_packages do
    case File.read("/run/reboot-required.pkgs") do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.take(50)
      _ -> []
    end
  end

  defp push(type, payload) do
    case Event.new(type, payload) do
      {:ok, event} ->
        Outbox.push(event)

      {:error, errors} ->
        Logger.error("invalid #{type}: #{inspect(errors) |> String.slice(0, 400)}")
    end
  end
end
