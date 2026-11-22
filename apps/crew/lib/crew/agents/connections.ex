defmodule Crew.Agents.Connections do
  @moduledoc "The current channel for each box. Replacements take ownership before the old channel is notified."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def register(box_id), do: GenServer.call(__MODULE__, {:register, box_id, self()})
  def remove(box_id, pid), do: GenServer.call(__MODULE__, {:remove, box_id, pid})
  def lookup(box_id), do: :ets.lookup_element(__MODULE__, box_id, 2, nil)
  def ids, do: :ets.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, box_id, pid}, _from, refs) do
    {old, refs} = forget_monitor(box_id, refs)
    ref = Process.monitor(pid)
    :ets.insert(__MODULE__, {box_id, pid, ref})
    if old && old != pid, do: send(old, :replaced)
    {:reply, self(), Map.put(refs, ref, box_id)}
  end

  def handle_call({:remove, box_id, pid}, _from, refs) do
    if lookup(box_id) == pid do
      {_, refs} = forget_monitor(box_id, refs)
      :ets.delete(__MODULE__, box_id)
      {:reply, true, refs}
    else
      {:reply, false, refs}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, refs) do
    {box_id, refs} = Map.pop(refs, ref)
    if box_id, do: :ets.delete(__MODULE__, box_id)
    {:noreply, refs}
  end

  defp forget_monitor(box_id, refs) do
    case :ets.lookup(__MODULE__, box_id) do
      [{_, pid, ref}] ->
        Process.demonitor(ref, [:flush])
        {pid, Map.delete(refs, ref)}

      [] ->
        {nil, refs}
    end
  end
end
