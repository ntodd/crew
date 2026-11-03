defmodule CrewAgent.Handler do
  @moduledoc """
  What each command does on the agent (§10.3). The vocabulary is fixed;
  every payload has already been validated by `CrewProtocol.Command`.
  """

  alias CrewAgent.{Images, Reporter, VMs}
  alias CrewProtocol.Command

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

  def handle(%Command{type: type}) when type in ["cache.config", "cache.purge"],
    do: {:error, "no_cache", "this box has no registry cache configured"}

  def handle(%Command{type: type}),
    do: {:error, "unsupported", "#{type} isn't supported by this agent yet"}
end
