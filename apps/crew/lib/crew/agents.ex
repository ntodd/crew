defmodule Crew.Agents do
  @moduledoc """
  Connected agents (§10): who's online, sending them commands, and what
  their events do. An agent may only report on its own box's VMs and
  operations; anything else is refused and logged (§10.4).
  """

  require Logger

  alias Crew.{Boxes, Metrics, Operations, VMs}
  alias CrewProtocol.{Command, Event}

  @registry Crew.Registry

  @doc "Registers the calling channel as `box_id`'s agent, replacing any older connection."
  def register(box_id) do
    case Registry.lookup(@registry, {:agent, box_id}) do
      [{pid, _}] when pid != self() ->
        send(pid, :replaced)
        Registry.unregister_match(@registry, {:agent, box_id}, :_)
        wait_unregistered(box_id, pid, 50)

      _ ->
        :ok
    end

    case Registry.register(@registry, {:agent, box_id}, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  # The old channel unregisters itself as it stops.
  defp wait_unregistered(_box_id, _pid, 0), do: :ok

  defp wait_unregistered(box_id, pid, n) do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_unregistered(box_id, pid, n - 1)
    else
      :ok
    end
  end

  def online?(box_id), do: Registry.lookup(@registry, {:agent, box_id}) != []

  def online_ids do
    Registry.select(@registry, [{{{:agent, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "Sends a command to the box's agent. `{:error, :offline}` if it isn't connected."
  def send_command(box_id, %Command{} = cmd) do
    case Registry.lookup(@registry, {:agent, box_id}) do
      [{pid, _} | _] ->
        send(pid, {:dispatch, cmd})
        :ok

      [] ->
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
    case Registry.lookup(@registry, {:agent, box_id}) do
      [{^pid, _}] -> :ok
      [] -> :ok
      _other -> :replaced
    end
    |> case do
      :replaced ->
        :ok

      :ok ->
        Boxes.agent_left(box_id)
        VMs.agent_left(box_id)
    end
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
