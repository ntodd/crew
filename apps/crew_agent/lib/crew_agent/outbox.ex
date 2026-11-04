defmodule CrewAgent.Outbox do
  @moduledoc """
  Holds events for the control plane while the socket is down.

  VMs and operations keep running when the connection drops, so their
  events queue here until the next connection attaches:

  - **Reliable** (`op.result`, `vm.state`, `vm.exited`) are kept until the
    control plane acknowledges them, and redelivered on every attach.
  - **Snapshots** keep only the latest: per box (`box.*`),
    per VM (`vm.metrics`, `vm.steps`) and per image (`image.state`).
    `cache.stats` are differences, so queued ones are added up.
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

  @doc "Whether a connection is attached, to deliver to and acknowledge."
  def attached?(server \\ __MODULE__), do: GenServer.call(server, :attached?)

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

  def handle_call(:attached?, _from, state), do: {:reply, state.conn != nil, state}

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

  # cache.stats are differences since the last report: queued ones add
  # up (bytes_stored, a level, and the top list are the latest's).
  defp enqueue(state, seq, %Event{type: "cache.stats"} = event) do
    {queued, rest} =
      state.pending
      |> :queue.to_list()
      |> Enum.split_with(fn {_, e} -> e.type == "cache.stats" end)

    event = Enum.reduce(queued, event, fn {_, older}, acc -> add_stats(older, acc) end)
    %{state | pending: :queue.from_list(rest ++ [{seq, event}])}
  end

  # Snapshots: only the latest for the same thing matters once the
  # connection is back.
  defp enqueue(state, seq, %Event{} = event) do
    key = snapshot_key(event)
    pending = :queue.filter(fn {_, e} -> snapshot_key(e) != key end, state.pending)
    %{state | pending: :queue.in({seq, event}, pending)}
  end

  defp add_stats(%Event{payload: older}, %Event{payload: newer} = event) do
    by_host = Map.new(older.hosts, &{&1.host, &1})

    hosts =
      for h <- newer.hosts do
        was = by_host[h.host] || %{}
        sum = fn k -> Map.get(h, k, 0) + Map.get(was, k, 0) end
        %{h | hits: sum.(:hits), misses: sum.(:misses), bytes_served: sum.(:bytes_served)}
      end

    gone = for h <- older.hosts, not Enum.any?(newer.hosts, &(&1.host == h.host)), do: h

    %{
      event
      | payload: %{
          newer
          | hosts: hosts ++ gone,
            evictions: newer.evictions + older.evictions,
            digest_mismatches: newer.digest_mismatches + older.digest_mismatches
        }
    }
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
