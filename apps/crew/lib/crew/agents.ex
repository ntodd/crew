defmodule Crew.Agents do
  @moduledoc """
  Connected agents (§10): who's online, sending them commands, and what
  their events do. An agent may only report on its own box's VMs and
  operations; anything else is refused and logged (§10.4).
  """

  require Logger

  alias Crew.{Boxes, Metrics, Operations, VMs}
  alias Crew.Agents.Connections
  alias CrewProtocol.{Command, Event}

  @doc "Registers the calling channel as the current connection for a box."
  def register(box_id) do
    with_box_lock(box_id, fn -> Connections.register(box_id) end)
    :ok
  end

  @doc "Record the join and replace the channel under the same lock as a disconnect."
  def register_channel(box_id, join) do
    with_box_lock(box_id, fn ->
      case Boxes.get(box_id) do
        %Boxes.Box{revoked_at: nil} = box ->
          monitor = box_id |> Connections.register() |> Process.monitor()
          {:ok, Boxes.agent_joined(box, join), monitor}

        _ ->
          {:error, :unauthorized}
      end
    end)
  end

  def online?(box_id), do: Connections.lookup(box_id) != nil
  def online_ids, do: Connections.ids()

  defp with_box_lock(box_id, fun),
    do: :global.trans({{__MODULE__, box_id}, self()}, fun, [node()])

  @doc "Sends a command to the box's agent. `{:error, :offline}` if it isn't connected."
  def send_command(box_id, %Command{} = cmd) do
    case Connections.lookup(box_id) do
      pid when is_pid(pid) ->
        send(pid, {:dispatch, cmd})
        :ok

      nil ->
        {:error, :offline}
    end
  end

  @doc "After a join: the box is online, and what depends on that is told."
  def joined(box, join, _remote_ip) do
    VMs.agent_joined(box, join)
    # Its cache gets the deployment's config (§15.8), rotating its CA if
    # a rotation happened while it was away.
    Crew.Caches.push(box.id)
    # The version it joined on settles an update under way, and a box
    # behind its target version gets one (§20.2).
    Crew.Agents.Updates.joined(box, join)
    :ok
  end

  @doc "The channel closed. Only the current connection's leaving takes the box offline."
  def left(box_id, pid) do
    with_box_lock(box_id, fn ->
      if Connections.remove(box_id, pid) do
        Boxes.agent_left(box_id)
        VMs.agent_left(box_id)
      end

      :ok
    end)
  end

  # -- events (§10.4) ---------------------------------------------------------------

  @doc "Applies an event from `box_id`'s agent."
  def handle_event(box_id, %Event{type: "op.result", payload: payload}),
    do: Operations.record_result(box_id, payload)

  def handle_event(box_id, %Event{type: "box.capabilities", payload: caps}) do
    if caps.driver == "null" and not Crew.Config.dev?() do
      Logger.warning("refused the null driver on box #{box_id}: it's for development only")
      {:error, "the null driver is for development only"}
    else
      box = Boxes.get!(box_id)
      {:ok, _} = Boxes.report_capabilities(box, caps)
      :ok
    end
  end

  def handle_event(box_id, %Event{type: "box.metrics", payload: m}) do
    Metrics.record_box(box_id, m)
    Boxes.seen(box_id)
    :ok
  end

  def handle_event(box_id, %Event{type: "box.reboot", payload: r}) do
    Boxes.report_reboot(Boxes.get!(box_id), r)
    :ok
  end

  def handle_event(box_id, %Event{type: type} = event)
      when type in ["box.inventory", "image.state", "cache.stats"] or
             binary_part(type, 0, 3) == "vm." do
    VMs.handle_agent_event(box_id, event)
  end

  def handle_event(_box_id, %Event{type: type}), do: {:error, "unhandled event #{type}"}
end
