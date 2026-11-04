defmodule Crew.Logs.Stream do
  @moduledoc """
  One VM's live log (§16.2): batches stored in `seq` order, whatever order
  they arrive in.

  - A batch past a gap waits while `vm.log.resend` asks for the missing
    ones. A gap still open after 10 s, or answered with `vm.log.gone`,
    gets a `[N lines lost]` line, and the stream goes on.
  - What's stored is acked once a second (`vm.log.ack`).
  - A new epoch (the agent adopted or restarted the VM) restarts `seq`;
    line numbers go on from the last stored one.

  Its position (epoch, seq, line number) is on the VM's row, so a stream
  that restarts picks up where it was. It stops a minute after its last
  batch, and starts again with the next.
  """
  use GenServer, restart: :transient

  import Ecto.Query, only: [from: 2]

  alias Crew.{Agents, Logs, Repo}
  alias Crew.Logs.Index
  alias Crew.VMs.VM
  alias CrewProtocol.Command

  @registry Crew.Registry
  @segment 1000
  @idle_ms 60_000

  def timer(name) do
    defaults = %{ack: 1_000, gap: 10_000}
    Map.get(Application.get_env(:crew, :log_timers_ms, %{}), name, defaults[name])
  end

  def start_link(vm_id),
    do:
      GenServer.start_link(__MODULE__, vm_id,
        name: {:via, Registry, {@registry, {:log_stream, vm_id}}}
      )

  def child_spec(vm_id),
    do: %{id: {__MODULE__, vm_id}, start: {__MODULE__, :start_link, [vm_id]}, restart: :transient}

  @doc "Hands an agent's log event to the VM's stream, starting it if need be."
  def deliver(vm_id, message) do
    pid =
      case Registry.lookup(@registry, {:log_stream, vm_id}) do
        [{pid, _}] ->
          pid

        [] ->
          case DynamicSupervisor.start_child(Crew.Logs.Supervisor, {__MODULE__, vm_id}) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end
      end

    GenServer.cast(pid, message)
  end

  # -- state ---------------------------------------------------------------------

  @impl true
  def init(vm_id) do
    vm = Repo.get!(VM, vm_id)
    path = Logs.path(:vm, vm_id)
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(path, [:append, :raw, :binary])
    {:ok, size} = :file.position(io, :eof)
    {seg_first, seg_offset} = Logs.open_segment(:vm, vm_id)

    {:ok,
     %{
       vm_id: vm_id,
       box_id: vm.box_id,
       io: io,
       size: size,
       epoch: vm.log_epoch,
       next_seq: vm.last_log_seq + 1,
       n: vm.last_log_n,
       agent_n: nil,
       pending: %{},
       gap: nil,
       acked: vm.last_log_seq,
       ack_timer: nil,
       seg_first: seg_first,
       seg_offset: seg_offset,
       index: Logs.index(:vm, vm_id),
       index_dirty: false
     }, @idle_ms}
  end

  @impl true
  def handle_cast({:log, %{epoch: epoch, seq: seq, lines: lines}}, state) do
    state = if epoch != state.epoch, do: new_epoch(state, epoch), else: state

    state =
      cond do
        seq < state.next_seq -> state
        seq == state.next_seq -> state |> store(seq, lines) |> drain()
        true -> await_gap(%{state | pending: Map.put(state.pending, seq, lines)})
      end

    {:noreply, schedule_ack(state), @idle_ms}
  end

  def handle_cast({:gone, %{epoch: epoch, up_to_seq: up_to}}, %{epoch: epoch} = state) do
    state = if up_to >= state.next_seq, do: state |> skip_to(up_to + 1) |> drain(), else: state
    {:noreply, schedule_ack(state), @idle_ms}
  end

  def handle_cast({:gone, _}, state), do: {:noreply, state, @idle_ms}

  @impl true
  def handle_info({:gap_timeout, seq}, %{gap: seq} = state) do
    # The resend didn't fill it: mark what's lost and carry on from the
    # oldest batch that's here.
    next = state.pending |> Map.keys() |> Enum.min()
    {:noreply, state |> skip_to(next) |> drain() |> schedule_ack(), @idle_ms}
  end

  def handle_info({:gap_timeout, _}, state), do: {:noreply, state, @idle_ms}

  def handle_info(:ack, state) do
    state = %{state | ack_timer: nil} |> save_index()
    acked = state.next_seq - 1

    if acked > state.acked and state.epoch do
      notify(state, "vm.log.ack", %{
        "vm_id" => state.vm_id,
        "epoch" => state.epoch,
        "seq" => acked
      })

      {:noreply, %{state | acked: acked}, @idle_ms}
    else
      {:noreply, state, @idle_ms}
    end
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state, @idle_ms}

  @impl true
  def terminate(_reason, state) do
    save_index(state)
    :file.close(state.io)
  end

  # The index is saved with each ack, at most once a second.
  defp save_index(%{index_dirty: false} = state), do: state

  defp save_index(state) do
    File.write!(Logs.index_path(:vm, state.vm_id), Index.encode(state.index))
    Phoenix.PubSub.broadcast(Crew.PubSub, Logs.topic(state.vm_id), {:log_index, state.vm_id})
    %{state | index_dirty: false}
  end

  # -- epochs, gaps -----------------------------------------------------------------

  defp new_epoch(state, epoch) do
    %{state | epoch: epoch, next_seq: 1, acked: 0, pending: %{}, gap: nil, agent_n: nil}
  end

  defp await_gap(%{gap: nil} = state) do
    notify(state, "vm.log.resend", %{
      "vm_id" => state.vm_id,
      "epoch" => state.epoch,
      "from_seq" => state.next_seq
    })

    Process.send_after(self(), {:gap_timeout, state.next_seq}, timer(:gap))
    %{state | gap: state.next_seq}
  end

  defp await_gap(state), do: state

  # Lines up to `seq` won't come: one marker for them, counted by the
  # agent's own line numbers where it can be.
  defp skip_to(state, seq) do
    first_after =
      case state.pending[seq] do
        [%{n: n} | _] -> n
        _ -> nil
      end

    lost =
      if state.agent_n && first_after && first_after > state.agent_n + 1,
        do: "#{first_after - state.agent_n - 1} lines",
        else: "some lines"

    marker = %{n: nil, t: System.os_time(:millisecond), step_ref: nil, text: "[#{lost} lost]"}
    state = append(state, [marker], seq - 1)
    %{state | next_seq: seq, gap: nil, agent_n: first_after && first_after - 1}
  end

  defp drain(state) do
    case Map.pop(state.pending, state.next_seq) do
      {nil, _} ->
        if map_size(state.pending) > 0,
          do: await_gap(%{state | gap: nil}),
          else: %{state | gap: nil}

      {lines, pending} ->
        %{state | pending: pending} |> store(state.next_seq, lines) |> drain()
    end
  end

  defp store(state, seq, lines) do
    state = append(state, lines, seq)
    agent_n = lines |> List.last() |> then(&(&1 && &1.n)) || state.agent_n
    %{state | next_seq: seq + 1, agent_n: agent_n}
  end

  # -- storage (§16.3) ---------------------------------------------------------------

  defp append(state, [], _seq), do: state

  defp append(state, lines, seq) do
    {iodata, state, stored} =
      Enum.reduce(lines, {[], state, []}, fn line, {io, st, out} ->
        n = st.n + 1
        stored = %{n: n, t: line.t, step_ref: line[:step_ref], text: line.text}
        json = [Jason.encode_to_iodata!(stored), ?\n]
        st = %{st | n: n, size: st.size + IO.iodata_length(json)}
        st = if n - st.seg_first + 1 >= @segment, do: close_segment(st), else: st
        {[io | json], st, [stored | out]}
      end)

    :ok = :file.write(state.io, iodata)

    Repo.update_all(
      from(v in VM, where: v.id == ^state.vm_id),
      set: [log_epoch: state.epoch, last_log_seq: max(seq, 0), last_log_n: state.n]
    )

    stored = Enum.reverse(stored)

    Phoenix.PubSub.broadcast(
      Crew.PubSub,
      Logs.topic(state.vm_id),
      {:log_lines, state.vm_id, stored}
    )

    %{state | index: Index.add(state.index, stored), index_dirty: true}
  end

  defp close_segment(state) do
    Logs.put_segment(
      :vm,
      state.vm_id,
      state.seg_first,
      state.n,
      state.seg_offset,
      state.size - state.seg_offset
    )

    %{state | seg_first: state.n + 1, seg_offset: state.size}
  end

  defp schedule_ack(%{ack_timer: nil} = state) do
    if state.next_seq - 1 > state.acked,
      do: %{state | ack_timer: Process.send_after(self(), :ack, timer(:ack))},
      else: state
  end

  defp schedule_ack(state), do: state

  # Log acks and resends are notifications: no operation row, no result.
  defp notify(state, type, payload) do
    with {:ok, cmd} <- Command.new(type, payload) do
      Agents.send_command(state.box_id, cmd)
    end
  end
end
