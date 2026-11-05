defmodule CrewAgent.Handler do
  @moduledoc """
  What each command does on the agent (§10.3). The vocabulary is fixed;
  every payload has already been validated by `CrewProtocol.Command`.
  """

  alias CrewAgent.{Cache, Config, Images, Outbox, Reporter, Updater, VMs}
  alias CrewAgent.Driver.Firecracker
  alias CrewProtocol.Command

  require Logger

  @spec handle(Command.t()) :: :ok | {:ok, map()} | {:error, String.t(), String.t()}
  def handle(%Command{type: "vm.start"} = cmd), do: VMs.start(cmd)

  def handle(%Command{type: "vm.stop", payload: p}), do: VMs.stop(p.vm_id, p.force, p.grace_s)

  def handle(%Command{type: "vm.log.ack", payload: p}), do: VMs.log_ack(p.vm_id, p.epoch, p.seq)

  def handle(%Command{type: "vm.log.resend", payload: p}),
    do: VMs.log_resend(p.vm_id, p.epoch, p.from_seq)

  def handle(%Command{type: "image.prepare", payload: %{image: image}}), do: Images.prepare(image)
  def handle(%Command{type: "image.remove", payload: %{image_id: id}}), do: Images.remove(id)

  def handle(%Command{type: "box.inventory"}) do
    Reporter.report_inventory()
    :ok
  end

  def handle(%Command{type: "cache.config", payload: p}),
    do: Cache.configure(Config.get(), p)

  def handle(%Command{type: "cache.purge", payload: %{scope: s}}),
    do: Cache.purge(Config.get(), s)

  # Through crew-vmctl reboot on Firecracker boxes (§12.1).
  def handle(%Command{type: "box.restart", payload: p}) do
    case Config.get() do
      %Config{driver: "firecracker"} -> Firecracker.reboot(p.boot_id, p.force)
      _ -> {:error, "unsupported", "box.restart isn't supported by this driver yet"}
    end
  end

  # A mac-vz box's cache VM, through launchd (§12.1, CrewAgent.CacheVM).
  def handle(%Command{type: "cachevm.restart", payload: p}) do
    case Config.get() do
      %Config{driver: "vz"} = config -> CrewAgent.CacheVM.restart(config, p.boot_id)
      _ -> {:error, "unsupported", "only a mac-vz box has a cache VM"}
    end
  end

  # §20.2: installs the release, then exits once the result is out, for
  # the service manager to start the new one.
  def handle(%Command{type: "agent.update", payload: p, op_id: op_id}) do
    case Updater.run(p, Config.get(), op_id: op_id) do
      {:ok, %{"restart" => true} = result} ->
        restart_after_result()
        {:ok, result}

      other ->
        other
    end
  end

  def handle(%Command{type: type}),
    do: {:error, "unsupported", "#{type} isn't supported by this agent yet"}

  # Exits once every result (this update's among them) has been
  # acknowledged, or after 30 s regardless: a result that doesn't get
  # through is settled by the version the agent comes back on.
  defp restart_after_result do
    if Application.get_env(:crew_agent, :exit_after_update, true) do
      spawn(fn ->
        Process.sleep(500)

        if Updater.await(fn -> not Outbox.settled?() end, 200, 30_000) == :timeout,
          do: Logger.warning("restarting for the update before its result was acknowledged")

        Logger.info("exiting for the new release")
        System.stop(0)
      end)
    end

    :ok
  end
end
