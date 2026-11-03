defmodule CrewAgent.TestEvents do
  @moduledoc "Captures what the agent sends the control plane: attach the test to the outbox."
  import ExUnit.Assertions

  def attach do
    :ok = CrewAgent.Outbox.attach(self())
  end

  @doc "Waits for an event of `type` (matching `fun`), acking reliable ones."
  def await(type, fun \\ fn _ -> true end, timeout \\ 10_000) do
    receive do
      {:outbox_deliver, %CrewProtocol.Event{type: ^type, payload: payload} = event, ack} ->
        if ack, do: CrewAgent.Outbox.ack(ack)
        if fun.(payload), do: event, else: await(type, fun, timeout)

      {:outbox_deliver, _other, ack} ->
        if ack, do: CrewAgent.Outbox.ack(ack)
        await(type, fun, timeout)
    after
      timeout -> flunk("no #{type} event within #{timeout} ms")
    end
  end

  @doc "Every event until one matches `stop?`, in order (acking reliable ones)."
  def collect_until(stop?, timeout \\ 15_000, acc \\ []) do
    receive do
      {:outbox_deliver, %CrewProtocol.Event{} = event, ack} ->
        if ack, do: CrewAgent.Outbox.ack(ack)
        acc = [event | acc]
        if stop?.(event), do: Enum.reverse(acc), else: collect_until(stop?, timeout, acc)
    after
      timeout -> flunk("stopped waiting; got #{inspect(Enum.map(Enum.reverse(acc), & &1.type))}")
    end
  end

  def start_command(overrides \\ %{}) do
    vm_id = CrewProtocol.uuid7()

    payload =
      CrewProtocol.Examples.command("vm.start")
      |> Map.merge(%{
        "vm_id" => vm_id,
        "name" => CrewProtocol.Names.runner_name("ab12", "test", vm_id),
        "deadline" => System.os_time(:second) + 3600
      })
      |> Map.merge(overrides)

    {:ok, cmd} = CrewProtocol.Command.new("vm.start", payload)
    cmd
  end
end
