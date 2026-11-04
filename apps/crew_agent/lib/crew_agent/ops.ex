defmodule CrewAgent.Ops do
  @moduledoc """
  Runs commands from the control plane (Foreman's, trimmed).

  - **Idempotent by `op_id`:** a retry of one that's running is ignored;
    a retry of one that finished gets its stored result again.
  - **Ordered per subject:** commands for the same VM (or image) run one
    at a time, in arrival order; everything else at once.
  - **Cancellable:** `op.cancel` stops a running command's process, or
    drops a queued one.

  Each command runs in its own process and its result goes to the sink
  (the outbox) as `op.result`.
  """
  use GenServer

  alias CrewProtocol.{Command, Event, Text}

  require Logger

  @max_done 500
  @notifications ~w(vm.log.ack vm.log.resend)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec submit(GenServer.server(), Command.t()) :: :accepted | :duplicate
  def submit(server \\ __MODULE__, %Command{} = cmd), do: GenServer.call(server, {:submit, cmd})

  @spec in_flight(GenServer.server()) :: [String.t()]
  def in_flight(server \\ __MODULE__), do: GenServer.call(server, :in_flight)

  @impl true
  def init(opts) do
    {:ok,
     %{
       handler: Keyword.get(opts, :handler, &CrewAgent.Handler.handle/1),
       sink: Keyword.get(opts, :sink, &CrewAgent.Outbox.push/1),
       running: %{},
       pids: %{},
       queues: %{},
       known: MapSet.new(),
       done: %{},
       done_order: :queue.new()
     }}
  end

  @impl true
  def handle_call({:submit, %Command{type: "op.cancel"} = cmd}, _from, state) do
    state = cancel(state, cmd.payload.target_op_id)
    state.sink.(result_event(cmd.op_id, :ok))
    {:reply, :accepted, state}
  end

  # Log acks and resends (§16.2) come every second per VM and change
  # nothing worth a result: they're handled at once, with no op.result.
  def handle_call({:submit, %Command{type: type} = cmd}, _from, state)
      when type in @notifications do
    try do
      state.handler.(cmd)
    rescue
      e -> Logger.warning("#{type} failed: #{Exception.message(e)}")
    end

    {:reply, :accepted, state}
  end

  def handle_call({:submit, %Command{op_id: op_id} = cmd}, _from, state) do
    cond do
      Map.has_key?(state.done, op_id) ->
        state.sink.(state.done[op_id])
        {:reply, :duplicate, state}

      MapSet.member?(state.known, op_id) ->
        {:reply, :duplicate, state}

      true ->
        key = key(cmd)
        state = %{state | known: MapSet.put(state.known, op_id)}
        state = update_in(state.queues[key], &:queue.in(cmd, &1 || :queue.new()))
        {:reply, :accepted, maybe_start(state, key)}
    end
  end

  def handle_call(:in_flight, _from, state), do: {:reply, MapSet.to_list(state.known), state}

  @impl true
  def handle_info({:op_done, op_id, result}, state) do
    case Map.fetch(state.running, op_id) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, op_id, pid, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.fetch(state.pids, pid) do
      {:ok, op_id} ->
        Logger.error(
          "operation #{op_id} crashed: #{Exception.format_exit(reason) |> String.slice(0, 500)}"
        )

        {:noreply, finish(state, op_id, pid, {:error, "crashed", "the agent's handler crashed"})}

      :error ->
        {:noreply, state}
    end
  end

  defp key(%Command{payload: %{vm_id: vm_id}}), do: {:vm, vm_id}
  defp key(%Command{payload: %{image: %{id: id}}}), do: {:image, id}
  defp key(%Command{payload: %{image_id: id}}), do: {:image, id}
  defp key(%Command{op_id: op_id}), do: {:op, op_id}

  defp maybe_start(state, key) do
    busy? = Enum.any?(state.running, fn {_, r} -> r.key == key end)

    case {busy?, :queue.out(state.queues[key] || :queue.new())} do
      {true, _} ->
        state

      {false, {:empty, _}} ->
        %{state | queues: Map.delete(state.queues, key)}

      {false, {{:value, cmd}, rest}} ->
        state = %{state | queues: Map.put(state.queues, key, rest)}
        start(state, cmd, key)
    end
  end

  defp start(state, cmd, key) do
    parent = self()
    handler = state.handler
    op_id = cmd.op_id

    {pid, ref} =
      spawn_monitor(fn ->
        Logger.metadata(op_id: op_id)
        send(parent, {:op_done, op_id, handler.(cmd)})
      end)

    %{
      state
      | running: Map.put(state.running, op_id, %{pid: pid, ref: ref, key: key}),
        pids: Map.put(state.pids, pid, op_id)
    }
  end

  defp finish(state, op_id, pid, result) do
    %{key: key} = state.running[op_id]
    event = result_event(op_id, result)
    state.sink.(event)

    state
    |> Map.update!(:running, &Map.delete(&1, op_id))
    |> Map.update!(:pids, &Map.delete(&1, pid))
    |> Map.update!(:known, &MapSet.delete(&1, op_id))
    |> remember(op_id, event)
    |> maybe_start(key)
  end

  defp cancel(state, target) do
    case Map.fetch(state.running, target) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        finish(state, target, pid, {:error, "cancelled", "cancelled"})

      :error ->
        case Enum.find(state.queues, fn {_k, q} ->
               Enum.any?(:queue.to_list(q), &(&1.op_id == target))
             end) do
          {key, queue} ->
            event = result_event(target, {:error, "cancelled", "cancelled"})
            state.sink.(event)

            %{
              state
              | queues: Map.put(state.queues, key, :queue.filter(&(&1.op_id != target), queue)),
                known: MapSet.delete(state.known, target)
            }
            |> remember(target, event)

          nil ->
            if Map.has_key?(state.done, target),
              do: state,
              else:
                remember(state, target, result_event(target, {:error, "cancelled", "cancelled"}))
        end
    end
  end

  @doc false
  def result_event(op_id, result) do
    payload =
      case result do
        :ok ->
          %{op_id: op_id, status: "ok"}

        {:ok, map} when is_map(map) ->
          %{op_id: op_id, status: "ok", result: map}

        {:error, code, message} ->
          %{
            op_id: op_id,
            status: "error",
            error: %{
              code: code_of(code),
              message: message |> to_string() |> Text.scrub() |> Text.cut(2048) |> elem(0)
            }
          }

        {:error, code} ->
          %{op_id: op_id, status: "error", error: %{code: code_of(code), message: inspect(code)}}

        other ->
          %{
            op_id: op_id,
            status: "error",
            error: %{code: "unexpected", message: inspect(other) |> String.slice(0, 500)}
          }
      end

    case Event.new("op.result", payload) do
      {:ok, event} ->
        event

      {:error, errors} ->
        Logger.error("invalid op.result for #{op_id}: #{inspect(errors)}")

        {:ok, event} =
          Event.new("op.result", %{
            op_id: op_id,
            status: "error",
            error: %{code: "invalid_result", message: "invalid result"}
          })

        event
    end
  end

  defp code_of(code) when is_atom(code), do: code |> Atom.to_string() |> code_of()

  defp code_of(code) when is_binary(code) do
    code = code |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_") |> String.slice(0, 64)
    if Regex.match?(~r/\A[a-z]/, code), do: code, else: "error_" <> code
  end

  defp code_of(_), do: "error"

  defp remember(state, op_id, event) do
    order = :queue.in(op_id, state.done_order)
    done = Map.put(state.done, op_id, event)

    if :queue.len(order) > @max_done do
      {{:value, oldest}, order} = :queue.out(order)
      %{state | done: Map.delete(done, oldest), done_order: order}
    else
      %{state | done: done, done_order: order}
    end
  end
end
