defmodule Crew.VMs do
  @moduledoc """
  VM rows and their lifecycle (§8.6). The agent's VM events, inventory,
  image states and cache stats arrive here. The full state machine
  (`Crew.VMs.Server`) comes with the scheduler; until then the events
  are accepted and the inventory is kept for the box page.
  """

  @doc false
  def agent_joined(_box, _join), do: :ok

  @doc false
  def agent_left(_box_id), do: :ok

  @doc "An event from a box's agent about its VMs, images or cache."
  def handle_agent_event(box_id, %CrewProtocol.Event{type: "box.inventory", payload: inventory}) do
    :persistent_term.put({__MODULE__, :inventory, box_id}, inventory)
    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{box_id}", {:box_changed, box_id})
    :ok
  end

  def handle_agent_event(_box_id, %CrewProtocol.Event{}), do: :ok

  @doc "The last inventory a box's agent sent, if any."
  def inventory(box_id), do: :persistent_term.get({__MODULE__, :inventory, box_id}, nil)
end
