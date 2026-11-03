defmodule Crew.GitHub.Budget do
  @moduledoc """
  The GitHub API budget, per installation (§6.6).

  - **Tracks** `x-ratelimit-remaining`, `-limit` and `-reset` from every
    response.
  - **Classes:** below 20% of the hourly budget, `:essential` calls are
    still made, `:normal` ones wait for the reset, and `:optional` ones
    are skipped.
  - **At most 20 requests in flight.** Callers wait for a slot (up to
    `:wait` ms); a caller that dies gives its slot back.
  - **Writes are paced** under GitHub's secondary limit on
    content-creating requests: 60 a minute and 450 an hour, as sliding
    windows. JIT generation is served first: other writes (runner
    deletes for reaping) leave the last 10 a minute and 30 an hour to
    it.
  - **Backs off** on 429, or a 403 with nothing left, until `retry-after`
    or the reset.

  Kinds: `:read`, `:jit` (generating a JIT config) and `:delete`/
  `:write` (any other POST, PATCH or DELETE).
  """
  use GenServer

  @max_in_flight 20
  @low_fraction 0.2
  @minute 60_000
  @hour 3_600_000
  @minute_writes 60
  @hour_writes 450
  @minute_reserve 10
  @hour_reserve 30

  @type class :: :essential | :normal | :optional
  @type kind :: :read | :jit | :delete | :write

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Takes a slot for a request. `{:ok, ref}` must be followed by
  `release/5` with the response.
  """
  @spec acquire(GenServer.server(), term(), class(), kind(), keyword()) ::
          {:ok, reference()}
          | {:error,
             :skipped
             | :busy
             | {:delayed, integer()}
             | {:backoff, integer()}
             | {:write_limited, integer()}}
  def acquire(server \\ __MODULE__, installation, class, kind, opts \\ []) do
    wait = Keyword.get(opts, :wait, 30_000)
    GenServer.call(server, {:acquire, installation, class, kind, wait}, wait + 5_000)
  end

  @doc "Gives a slot back, with the response's status and headers."
  def release(server \\ __MODULE__, installation, ref, status, headers) do
    GenServer.cast(server, {:release, installation, ref, status, headers})
    :ok
  end

  @doc false
  # Tests share the app's budget; this forgets everything.
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @doc "What's known about an installation's budget, for the Deployment page."
  def info(server \\ __MODULE__, installation),
    do: GenServer.call(server, {:info, installation})

  # -- server ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    now = Keyword.get(opts, :now, fn -> System.os_time(:millisecond) end)
    {:ok, %{now: now, installations: %{}, monitors: %{}}}
  end

  defp blank do
    %{
      remaining: nil,
      limit: nil,
      reset_ms: nil,
      backoff_until: nil,
      in_flight: %{},
      waiters: :queue.new(),
      writes: :queue.new()
    }
  end

  defp inst(state, id), do: Map.get(state.installations, id, blank())
  defp put_inst(state, id, inst), do: put_in(state, [:installations, id], inst)

  @impl true
  def handle_call(:reset, _from, state) do
    for {monitor, _} <- state.monitors, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | installations: %{}, monitors: %{}}}
  end

  def handle_call({:info, id}, _from, state) do
    inst = inst(state, id)

    {:reply,
     %{
       remaining: inst.remaining,
       limit: inst.limit,
       reset_ms: inst.reset_ms,
       in_flight: map_size(inst.in_flight),
       backoff_until: inst.backoff_until
     }, state}
  end

  def handle_call({:acquire, id, class, kind, wait}, {pid, _} = from, state) do
    now = state.now.()
    inst = inst(state, id)

    with :ok <- check_backoff(inst, now),
         :ok <- check_budget(inst, class, now),
         :ok <- check_writes(inst, kind, now) do
      cond do
        map_size(inst.in_flight) < @max_in_flight ->
          {ref, state} = grant(state, id, inst, pid, kind, now)
          {:reply, {:ok, ref}, state}

        wait <= 0 ->
          {:reply, {:error, :busy}, state}

        true ->
          timer = Process.send_after(self(), {:wait_timeout, id, from}, wait)
          inst = %{inst | waiters: :queue.in({from, class, kind, timer}, inst.waiters)}
          {:noreply, put_inst(state, id, inst)}
      end
    else
      error -> {:reply, error, state}
    end
  end

  defp check_backoff(%{backoff_until: until}, now) when is_integer(until) and until > now,
    do: {:error, {:backoff, until}}

  defp check_backoff(_inst, _now), do: :ok

  defp check_budget(%{remaining: r, limit: l, reset_ms: reset}, class, now)
       when is_integer(r) and is_integer(l) and l > 0 and is_integer(reset) and reset > now and
              r < l * @low_fraction do
    case class do
      :essential -> :ok
      :normal -> {:error, {:delayed, reset}}
      :optional -> {:error, :skipped}
    end
  end

  defp check_budget(_inst, _class, _now), do: :ok

  defp check_writes(_inst, :read, _now), do: :ok

  defp check_writes(inst, kind, now) do
    writes = drop_old(inst.writes, now - @hour)
    in_minute = count_since(writes, now - @minute)
    in_hour = :queue.len(writes)

    {minute_cap, hour_cap} =
      if kind == :jit,
        do: {@minute_writes, @hour_writes},
        else: {@minute_writes - @minute_reserve, @hour_writes - @hour_reserve}

    cond do
      in_minute >= minute_cap ->
        {:error, {:write_limited, nth_from_end(writes, in_minute) + @minute}}

      in_hour >= hour_cap ->
        {:error, {:write_limited, oldest(writes) + @hour}}

      true ->
        :ok
    end
  end

  defp drop_old(queue, cutoff) do
    case :queue.peek(queue) do
      {:value, t} when t <= cutoff -> drop_old(:queue.drop(queue), cutoff)
      _ -> queue
    end
  end

  defp count_since(queue, cutoff), do: queue |> :queue.to_list() |> Enum.count(&(&1 > cutoff))

  # The oldest write inside the last minute: the first of the last `n`.
  defp nth_from_end(queue, n) do
    list = :queue.to_list(queue)
    Enum.at(list, length(list) - n)
  end

  defp oldest(queue), do: elem(:queue.peek(queue), 1)

  defp grant(state, id, inst, pid, kind, now) do
    ref = make_ref()
    monitor = Process.monitor(pid)

    writes =
      if kind == :read,
        do: inst.writes,
        else: inst.writes |> drop_old(now - @hour) |> then(&:queue.in(now, &1))

    inst = %{inst | in_flight: Map.put(inst.in_flight, ref, monitor), writes: writes}
    state = put_in(state, [:monitors, monitor], {id, ref})
    {ref, put_inst(state, id, inst)}
  end

  @impl true
  def handle_cast({:release, id, ref, status, headers}, state) do
    now = state.now.()
    inst = inst(state, id)

    state =
      case Map.pop(inst.in_flight, ref) do
        {nil, _} ->
          state

        {monitor, in_flight} ->
          Process.demonitor(monitor, [:flush])
          {_, state} = pop_in(state, [:monitors, monitor])
          put_inst(state, id, %{inst | in_flight: in_flight})
      end

    inst = state |> inst(id) |> track(status, headers, now)
    {:noreply, state |> put_inst(id, inst) |> serve_waiters(id)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {{id, ref}, monitors} ->
        inst = inst(state, id)
        inst = %{inst | in_flight: Map.delete(inst.in_flight, ref)}
        {:noreply, %{state | monitors: monitors} |> put_inst(id, inst) |> serve_waiters(id)}
    end
  end

  def handle_info({:wait_timeout, id, from}, state) do
    inst = inst(state, id)

    {timed_out, rest} =
      inst.waiters |> :queue.to_list() |> Enum.split_with(fn {f, _, _, _} -> f == from end)

    if timed_out != [], do: GenServer.reply(from, {:error, :busy})
    {:noreply, put_inst(state, id, %{inst | waiters: :queue.from_list(rest)})}
  end

  defp serve_waiters(state, id) do
    inst = inst(state, id)

    with true <- map_size(inst.in_flight) < @max_in_flight,
         {{:value, {{pid, _} = from, class, kind, timer}}, waiters} <- :queue.out(inst.waiters) do
      Process.cancel_timer(timer)
      now = state.now.()
      inst = %{inst | waiters: waiters}

      # Everything is checked again: a backoff or a low budget may have
      # arrived while it waited.
      checked =
        with :ok <- check_backoff(inst, now),
             :ok <- check_budget(inst, class, now),
             do: check_writes(inst, kind, now)

      state =
        case checked do
          :ok ->
            {ref, state} = grant(state, id, inst, pid, kind, now)
            GenServer.reply(from, {:ok, ref})
            state

          error ->
            GenServer.reply(from, error)
            put_inst(state, id, inst)
        end

      serve_waiters(state, id)
    else
      _ -> state
    end
  end

  defp track(inst, status, headers, now) do
    remaining = header_int(headers, "x-ratelimit-remaining")
    limit = header_int(headers, "x-ratelimit-limit")
    reset = header_int(headers, "x-ratelimit-reset")

    inst = %{
      inst
      | remaining: remaining || inst.remaining,
        limit: limit || inst.limit,
        reset_ms: if(reset, do: reset * 1000, else: inst.reset_ms)
    }

    retry_after = header_int(headers, "retry-after")

    cond do
      status == 429 or (status == 403 and retry_after != nil) ->
        %{inst | backoff_until: now + (retry_after || 60) * 1000}

      status == 403 and remaining == 0 and inst.reset_ms ->
        %{inst | backoff_until: inst.reset_ms}

      true ->
        inst
    end
  end

  defp header_int(headers, name) do
    case headers[name] do
      [value | _] -> parse_int(value)
      value when is_binary(value) -> parse_int(value)
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> nil
    end
  end
end
