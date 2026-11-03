defmodule CrewAgent.Outbox do
  @moduledoc """
  Holds events for the control plane while the socket is down.

  VMs and operations keep running when the connection drops, so their
  events queue here until the next connection attaches:

  - **Reliable** (`op.result`, `vm.state`, `vm.exited`) are kept until the
    control plane acknowledges them, and redelivered on every attach.
  - **Snapshots** keep only the latest: per box (`box.*`, `cache.stats`),
    per VM (`vm.metrics`, `vm.steps`) and per image (`image.state`).
  - **Logs** (`vm.log`, `vm.log.gone`) aren't queued at all: each VM keeps
    its unacknowledged batches and resends them when a connection
    attaches (§16.2).

  The attached connection receives `{:outbox_deliver, event, ack_id}`;
  `ack_id` is nil for events that need no acknowledgement.
  """
  use GenServer

  alias CrewProtocol.Event

  @reliable ["op.result", "vm.state", "vm.exited"]
  @live_only ["vm.log", "vm.log.gone"]

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def push(server \\ __MODULE__, %Event{} = event), do: GenServer.cast(server, {:push, event})
  def attach(server \\ __MODULE__, pid), do: GenServer.call(server, {:attach, pid})
  def detach(server \\ __MODULE__), do: GenServer.call(server, :detach)
  def ack(server \\ __MODULE__, ack_id), do: GenServer.cast(server, {:ack, ack_id})

  @doc "True when every result has been delivered and acknowledged."
  def settled?(server \\ __MODULE__), do: GenServer.call(server, :settled?)

  @impl true
  def init(_opts) do
    {:ok,
     %{
       conn: nil,
       monitor: nil,
       # Unsent events, oldest first, as {seq, event}.
       pending: :queue.new(),
       # Reliable events sent but not acked: seq => event.
       unacked: %{},
       seq: 0
     }}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    seq = state.seq + 1
    state = %{state | seq: seq}

    if state.conn do
      {:noreply, deliver(state, seq, event)}
    else
      {:noreply, enqueue(state, seq, event)}
    end
  end

  def handle_cast({:ack, seq}, state),
    do: {:noreply, %{state | unacked: Map.delete(state.unacked, seq)}}

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    state = demonitor(state)
    state = %{state | conn: pid, monitor: Process.monitor(pid)}

    # Unacked results first (they're older), then everything queued.
    state =
      state.unacked
      |> Enum.sort()
      |> Enum.reduce(state, fn {seq, event}, acc -> deliver(acc, seq, event) end)

    pending = :queue.to_list(state.pending)
    state = %{state | pending: :queue.new()}
    state = Enum.reduce(pending, state, fn {seq, event}, acc -> deliver(acc, seq, event) end)
    {:reply, :ok, state}
  end

  def handle_call(:settled?, _from, state) do
    pending_results? =
      Enum.any?(:queue.to_list(state.pending), fn {_, e} -> e.type in @reliable end)

    {:reply, state.unacked == %{} and not pending_results?, state}
  end

  def handle_call(:detach, _from, state),
    do: {:reply, :ok, state |> demonitor() |> Map.put(:conn, nil)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, %{state | conn: nil, monitor: nil}}
  end

  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}

  defp deliver(state, seq, %Event{type: type} = event) when type in @reliable do
    send(state.conn, {:outbox_deliver, event, seq})
    %{state | unacked: Map.put(state.unacked, seq, event)}
  end

  defp deliver(state, _seq, event) do
    send(state.conn, {:outbox_deliver, event, nil})
    state
  end

  defp enqueue(state, seq, %Event{type: type} = event) when type in @reliable do
    %{state | pending: :queue.in({seq, event}, state.pending)}
  end

  defp enqueue(state, _seq, %Event{type: type}) when type in @live_only, do: state

  # Snapshots: only the latest for the same thing matters once the
  # connection is back.
  defp enqueue(state, seq, %Event{} = event) do
    key = snapshot_key(event)
    pending = :queue.filter(fn {_, e} -> snapshot_key(e) != key end, state.pending)
    %{state | pending: :queue.in({seq, event}, pending)}
  end

  defp snapshot_key(%Event{type: type, payload: %{vm_id: id}}), do: {type, id}
  defp snapshot_key(%Event{type: type, payload: %{image_id: id}}), do: {type, id}
  defp snapshot_key(%Event{type: type}), do: type

  defp demonitor(%{monitor: nil} = state), do: state

  defp demonitor(state) do
    Process.demonitor(state.monitor, [:flush])
    %{state | monitor: nil}
  end
end
