defmodule CrewGuest.Steps do
  @moduledoc """
  The job's steps as the guest sees them (§16.2), for `POST /v1/steps`.

  Two sources are merged, keyed by timeline record id:
  - **the worker log** (`_diag/Worker_*.log`, tailed and parsed by
    `CrewGuest.WorkerLog`): names, order, states, results and times;
  - **page activity** from `CrewGuest.Pages`: a record's first log line
    starts it, and a later record's first line means it's done.

  Whatever the worker log doesn't say falls back to page order: number `n`
  is the `n`th record seen and it's named "Step n". Steps are reported as
  `CrewProtocol.Guest.cast_steps/2` expects, at most 1000, through
  `:on_steps`, on each tick that changed something.

  The first worker log to appear means the worker has started, so
  `:on_job_started` is called then.
  """

  use GenServer

  alias CrewGuest.{StepRef, WorkerLog}

  @chunk 65_536
  @tick_budget 4 * 1_048_576
  @max_steps 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "A record had page lines from `first_t` to `last_t` (Unix ms)."
  def activity(server, record_id, first_t, last_t),
    do: GenServer.cast(server, {:activity, record_id, first_t, last_t})

  @doc "The job has ended: reads the rest of the worker log and reports the final steps."
  def finish(server, timeout \\ 5_000), do: GenServer.call(server, :finish, timeout)

  # Server

  @impl true
  def init(opts) do
    s = %{
      dir: Keyword.fetch!(opts, :diag_dir),
      on_steps: Keyword.fetch!(opts, :on_steps),
      on_job_started: Keyword.get(opts, :on_job_started, fn -> :ok end),
      tick_ms: Keyword.get(opts, :tick_ms, 250),
      logs: %{},
      records: %{},
      planned: %{},
      jobs: MapSet.new(),
      seq: 0,
      dirty: false,
      finished: false
    }

    send(self(), :tick)
    {:ok, s}
  end

  @impl true
  def handle_cast({:activity, id, first_t, last_t}, s) do
    id = String.downcase(id)

    s =
      cond do
        MapSet.member?(s.jobs, id) ->
          s

        Map.has_key?(s.records, id) ->
          update_in(s.records[id], fn r ->
            %{r | page_first: r.page_first || first_t, page_last: last_t}
          end)

        true ->
          # A new record's first line: the records before it are done.
          records = Map.new(s.records, fn {k, r} -> {k, done_if_paged(r)} end)
          s = %{s | records: records}
          {s, r} = new_record(s)
          put_in(s.records[id], %{r | page_first: first_t, page_last: last_t})
      end

    {:noreply, %{s | dirty: true}}
  end

  @impl true
  def handle_call(:finish, _from, s) do
    s = s |> read_logs(:infinity) |> flush_logs()
    records = Map.new(s.records, fn {k, r} -> {k, %{r | page_done: true}} end)
    s = %{s | records: records, finished: true}
    s.on_steps.(steps(s))
    {:reply, :ok, %{s | dirty: false}}
  end

  @impl true
  def handle_info(:tick, %{finished: true} = s), do: {:noreply, s}

  def handle_info(:tick, s) do
    s = read_logs(s, @tick_budget)

    s =
      if s.dirty do
        s.on_steps.(steps(s))
        %{s | dirty: false}
      else
        s
      end

    Process.send_after(self(), :tick, s.tick_ms)
    {:noreply, s}
  end

  # Records

  defp new_record(s) do
    seq = s.seq + 1

    record = %{
      seq: seq,
      name: nil,
      display_name: nil,
      order: nil,
      state: nil,
      conclusion: nil,
      started_at: nil,
      completed_at: nil,
      page_first: nil,
      page_last: nil,
      page_done: false
    }

    {%{s | seq: seq}, record}
  end

  defp done_if_paged(%{page_first: nil} = r), do: r
  defp done_if_paged(r), do: %{r | page_done: true}

  defp apply_update({:planned, id, name}, s), do: put_in(s.planned[id], name)

  defp apply_update({:job, id}, s),
    do: %{s | jobs: MapSet.put(s.jobs, id), records: Map.delete(s.records, id)}

  defp apply_update({:record, %{id: id} = update}, s) do
    if MapSet.member?(s.jobs, id) do
      s
    else
      {s, record} =
        case s.records do
          %{^id => record} -> {s, record}
          _ -> new_record(s)
        end

      put_in(s.records[id], Map.merge(record, Map.delete(update, :id)))
    end
  end

  # The steps, ordered by number.
  defp steps(s) do
    s.records
    |> Enum.map(fn {id, r} -> step(id, r, s) end)
    |> Enum.sort_by(&{&1.number, &1.seq})
    |> Enum.take(@max_steps)
    |> Enum.map(&Map.delete(&1, :seq))
  end

  defp step(id, r, s) do
    number = r.order || r.seq
    {status, conclusion} = status(r, s.finished)

    %{
      ref: StepRef.from(id),
      name: r.name || s.planned[id] || r.display_name || "Step #{number}",
      number: number,
      status: status,
      started_at: r.started_at || r.page_first,
      completed_at: r.completed_at || if(status == "completed", do: r.page_last),
      conclusion: conclusion,
      seq: r.seq
    }
  end

  # The worker log's state wins; pages are the fallback. Once the job has
  # ended nothing is still running, and a step that never started was
  # skipped.
  defp status(%{state: "completed"} = r, _finished?), do: {"completed", r.conclusion}
  defp status(%{state: "pending"} = r, true), do: {"completed", r.conclusion || "skipped"}
  defp status(%{page_first: nil, state: nil}, true), do: {"completed", "skipped"}
  defp status(r, true), do: {"completed", r.conclusion}
  defp status(%{state: state} = r, false) when state != nil, do: {state, r.conclusion}
  defp status(%{page_first: nil} = r, false), do: {"pending", r.conclusion}
  defp status(%{page_done: true} = r, false), do: {"completed", r.conclusion}
  defp status(r, false), do: {"in_progress", r.conclusion}

  # Worker logs

  defp read_logs(s, budget) do
    paths = Path.wildcard(Path.join(s.dir, "Worker_*.log"))
    s = Enum.reduce(paths, s, &open_log(&2, &1))

    Enum.reduce(s.logs, s, fn {path, log}, s ->
      {log, updates} = read_log(log, budget, [])
      s = Enum.reduce(updates, s, &apply_update/2)
      %{s | logs: Map.put(s.logs, path, log), dirty: s.dirty or updates != []}
    end)
  end

  defp open_log(s, path) do
    if Map.has_key?(s.logs, path) do
      s
    else
      case File.open(path, [:read, :binary, :raw]) do
        {:ok, io} ->
          if s.logs == %{}, do: s.on_job_started.()
          put_in(s.logs[path], %{io: io, parser: WorkerLog.new()})

        {:error, _} ->
          s
      end
    end
  end

  defp read_log(log, budget, acc) when is_integer(budget) and budget <= 0,
    do: {log, acc |> Enum.reverse() |> List.flatten()}

  defp read_log(log, budget, acc) do
    case :file.read(log.io, @chunk) do
      {:ok, data} ->
        {updates, parser} = WorkerLog.feed(log.parser, data)
        budget = if budget == :infinity, do: budget, else: budget - byte_size(data)
        read_log(%{log | parser: parser}, budget, [updates | acc])

      _eof_or_error ->
        {log, acc |> Enum.reverse() |> List.flatten()}
    end
  end

  defp flush_logs(s) do
    Enum.reduce(s.logs, s, fn {_path, log}, s ->
      {updates, _parser} = WorkerLog.flush(log.parser)
      File.close(log.io)
      Enum.reduce(updates, s, &apply_update/2)
    end)
    |> Map.put(:logs, %{})
  end
end
