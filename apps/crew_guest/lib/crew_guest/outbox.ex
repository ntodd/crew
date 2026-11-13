defmodule CrewGuest.Outbox do
  @moduledoc """
  Delivers states, steps and log lines to the guest API, and holds them
  while it can't be reached (§13.4, §13.5, §16.2).

  **Two lanes**, each with at most one request in flight, so crew-guest
  stays inside the agent's 4 connections per VM alongside the control poll
  and metrics:
  - **main:** states first, then the latest steps snapshot (coalesced, at
    most 2 requests a second);
  - **log:** NDJSON batches, sent every 250 ms or once 64 KiB is waiting,
    at most 1 MiB per request and 8 requests a second.

  **States** are sent at most once each and only forward
  (`runner_listening` → `job_started` → `job_finished`); a repeat, or one
  that would go backwards, is ignored. They're retried until delivered.

  **When the API can't be reached** (no answer, 408, 429 or 5xx), a lane
  retries with jittered backoff from 0.5 s to 5 s. Up to 16 MiB of logs and
  steps is held. Past that, the oldest log lines are dropped, and the next
  batch starts with one marker line saying how many. A log batch or steps
  snapshot that's still failing after 15 minutes is dropped too (and
  counted the same way). States are only ever dropped by poweroff.

  **Other answers:** a 413 on `/v1/log` means the VM's log limit is
  reached, so logs stop for good. Any other 4xx drops that one item.

  **Telemetry:** `[:crew_guest, :outbox, :start]` as each request (or
  retry) starts, with `monotonic_time` and `%{outbox, lane, kind}`. That's
  the instant the lanes are paced from; the request reaches the client a
  little later, once its task gets to run.
  """

  use GenServer

  require Logger

  alias CrewGuest.{API, Backoff}
  alias CrewProtocol.Text

  @ranks %{"runner_listening" => 1, "job_started" => 2, "job_finished" => 3}

  @defaults [
    batch_ms: 250,
    batch_bytes: 65_536,
    max_request_bytes: 1_048_576,
    buffer_bytes: 16 * 1_048_576,
    log_interval_ms: 125,
    steps_interval_ms: 500,
    max_steps_bytes: 262_144,
    backoff_min_ms: 500,
    backoff_max_ms: 5_000,
    give_up_ms: 15 * 60_000
  ]

  @max_text 65_536

  # Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Reports a state (`at` is now). Repeats and backward moves are ignored."
  def state(server, state, detail \\ nil) when is_map_key(@ranks, state),
    do: GenServer.cast(server, {:state, state, detail, System.system_time(:millisecond)})

  @doc "Replaces the steps snapshot to send."
  def steps(server, steps) when is_list(steps), do: GenServer.cast(server, {:steps, steps})

  @doc "Queues log lines: `%{t, step_ref, text}`."
  def log(server, lines) when is_list(lines), do: GenServer.cast(server, {:log, lines})

  @doc """
  Sends everything held now, without waiting for the batch tick. Returns
  `:ok` once it's all delivered, or `{:error, :timeout}` after `timeout` ms.
  """
  def flush(server, timeout), do: GenServer.call(server, {:flush, timeout}, timeout + 5_000)

  # Server

  @impl true
  def init(opts) do
    {:ok, sup} = Task.Supervisor.start_link()
    cfg = Map.new(Keyword.merge(@defaults, Keyword.take(opts, Keyword.keys(@defaults))))

    s = %{
      cfg: cfg,
      client: Keyword.fetch!(opts, :client),
      sup: sup,
      rank: 0,
      states: :queue.new(),
      steps: nil,
      logs: :queue.new(),
      log_bytes: 0,
      dropped: 0,
      logs_closed: false,
      batch_due: false,
      main: lane(),
      log: lane(),
      flushers: [],
      wake: nil
    }

    Process.send_after(self(), :tick, cfg.batch_ms)
    {:ok, s}
  end

  defp lane,
    do: %{task: nil, item: nil, attempt: 0, retry_at: nil, failing_since: nil, last_start: nil}

  @impl true
  def handle_cast({:state, state, detail, at}, s) do
    rank = Map.fetch!(@ranks, state)

    if rank > s.rank do
      body = %{state: state, at: at, detail: detail}
      pump(%{s | rank: rank, states: :queue.in(body, s.states)})
    else
      {:noreply, s}
    end
  end

  def handle_cast({:steps, steps}, s), do: pump(%{s | steps: fit_steps(steps, s.cfg)})

  def handle_cast({:log, _lines}, %{logs_closed: true} = s), do: {:noreply, s}

  def handle_cast({:log, lines}, s) do
    {logs, bytes} =
      Enum.reduce(lines, {s.logs, s.log_bytes}, fn line, {q, b} ->
        encoded = encode_line(line)
        {:queue.in(encoded, q), b + byte_size(encoded)}
      end)

    pump(trim(%{s | logs: logs, log_bytes: bytes}))
  end

  @impl true
  def handle_call({:flush, timeout}, from, s) do
    Process.send_after(self(), {:flush_timeout, from}, timeout)
    pump(%{s | flushers: [from | s.flushers]})
  end

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, s.cfg.batch_ms)
    pump(%{s | batch_due: true})
  end

  def handle_info(:wake, s), do: pump(%{s | wake: nil})

  def handle_info({:flush_timeout, from}, s) do
    if from in s.flushers do
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{s | flushers: List.delete(s.flushers, from)}}
    else
      {:noreply, s}
    end
  end

  def handle_info({ref, result}, s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    done(s, ref, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s), do: done(s, ref, {:error, reason})
  def handle_info(_msg, s), do: {:noreply, s}

  # Sending

  defp pump(s) do
    s = s |> pump_main() |> pump_log()
    {:noreply, s |> reply_flushers()}
  end

  defp pump_main(%{main: %{task: ref}} = s) when ref != nil, do: s

  defp pump_main(s) do
    now = now()

    cond do
      backing_off?(s.main, now) ->
        wake(s, s.main.retry_at)

      not :queue.is_empty(s.states) ->
        {{:value, body}, states} = :queue.out(s.states)
        start(%{s | states: states}, :main, {:state, body}, &API.post_state(&1, body))

      s.steps == nil ->
        s

      steps_wait(s, now) > 0 ->
        wake(s, now + steps_wait(s, now))

      true ->
        {body, _bytes} = s.steps
        start(%{s | steps: nil}, :main, {:steps, s.steps}, &API.post_steps(&1, body))
    end
  end

  defp backing_off?(%{retry_at: nil}, _now), do: false
  defp backing_off?(%{retry_at: at}, now), do: now < at

  defp steps_wait(%{main: %{last_steps: at}} = s, now), do: at + s.cfg.steps_interval_ms - now
  defp steps_wait(_s, _now), do: 0

  defp pump_log(%{log: %{task: ref}} = s) when ref != nil, do: s

  defp pump_log(s) do
    now = now()
    log_wait = log_wait(s, now)

    cond do
      backing_off?(s.log, now) ->
        wake(s, s.log.retry_at)

      s.log.item == nil and not batch_ready?(s) ->
        s

      log_wait > 0 ->
        wake(s, now + log_wait)

      s.log.item != nil ->
        {_, body, _bytes, _count} = item = s.log.item
        start(s, :log, item, &API.post_log(&1, body))

      true ->
        {item, s} = take_batch(s)
        {_, body, _bytes, _count} = item
        start(%{s | batch_due: false}, :log, item, &API.post_log(&1, body))
    end
  end

  defp log_wait(%{log: %{last_start: nil}}, _now), do: 0
  defp log_wait(s, now), do: s.log.last_start + s.cfg.log_interval_ms - now

  # A pending drop marker counts as something to send.
  defp batch_ready?(s) do
    (s.dropped > 0 or not :queue.is_empty(s.logs)) and
      (s.batch_due or s.flushers != [] or s.log_bytes >= s.cfg.batch_bytes)
  end

  defp start(s, lane_name, item, fun) do
    client = s.client
    task = Task.Supervisor.async_nolink(s.sup, fn -> fun.(client) end)
    at = System.monotonic_time()
    now = System.convert_time_unit(at, :native, :millisecond)
    meta = %{outbox: self(), lane: lane_name, kind: elem(item, 0)}
    :telemetry.execute([:crew_guest, :outbox, :start], %{monotonic_time: at}, meta)

    lane =
      s
      |> Map.fetch!(lane_name)
      |> Map.merge(%{task: task.ref, item: item, last_start: now})
      |> then(fn lane ->
        if match?({:steps, _}, item), do: Map.put(lane, :last_steps, now), else: lane
      end)

    Map.put(s, lane_name, lane)
  end

  defp done(s, ref, result) do
    cond do
      s.main.task == ref -> pump(finish(s, :main, classify(result)))
      s.log.task == ref -> pump(finish(s, :log, classify(result)))
      true -> {:noreply, s}
    end
  end

  defp classify({:ok, _status}), do: :ok
  defp classify({:error, {:status, 413}}), do: :too_large
  defp classify({:error, {:status, status}}) when status in [408, 429], do: :retry
  defp classify({:error, {:status, status}}) when status >= 500, do: :retry
  defp classify({:error, {:status, _status}}), do: :refused
  defp classify({:error, _reason}), do: :retry

  defp finish(s, lane_name, outcome) do
    lane = Map.fetch!(s, lane_name)
    item = lane.item
    s = Map.put(s, lane_name, %{lane | task: nil})

    case outcome do
      :ok ->
        settle(s, lane_name)

      :retry ->
        retry(s, lane_name, item)

      :too_large when lane_name == :log ->
        Logger.info("crew-guest: the VM's log limit is reached; no more log lines are sent")
        %{settle(s, :log) | logs_closed: true, logs: :queue.new(), log_bytes: 0, dropped: 0}

      _refused ->
        Logger.warning("crew-guest: the guest API refused #{describe(item)}; dropped it")
        s |> count_dropped(item) |> settle(lane_name)
    end
  end

  defp settle(s, lane_name) do
    lane = Map.fetch!(s, lane_name)
    Map.put(s, lane_name, %{lane | item: nil, attempt: 0, retry_at: nil, failing_since: nil})
  end

  defp retry(s, lane_name, item) do
    now = now()
    lane = Map.fetch!(s, lane_name)
    attempt = lane.attempt + 1
    failing_since = lane.failing_since || now

    lane = %{
      lane
      | attempt: attempt,
        failing_since: failing_since,
        retry_at: now + backoff(s, attempt)
    }

    s = Map.put(s, lane_name, lane)

    if now - failing_since >= s.cfg.give_up_ms and droppable?(item) do
      Logger.warning("crew-guest: gave up on #{describe(item)} after #{s.cfg.give_up_ms} ms")

      s
      |> count_dropped(item)
      |> settle(lane_name)
      |> put_in([lane_name, :retry_at], lane.retry_at)
    else
      requeue(s, lane_name, item)
    end
  end

  # The main lane picks its next item afresh, so a state that arrives
  # while steps are failing isn't stuck behind them.
  defp requeue(s, :main, {:state, body}),
    do: %{s | states: :queue.in_r(body, s.states), main: %{s.main | item: nil}}

  defp requeue(s, :main, {:steps, steps}),
    do: %{s | steps: s.steps || steps, main: %{s.main | item: nil}}

  defp requeue(s, :log, _item), do: s

  defp droppable?({:state, _}), do: false
  defp droppable?(_item), do: true

  defp count_dropped(s, {:log, _body, _bytes, count}), do: %{s | dropped: s.dropped + count}
  defp count_dropped(s, _item), do: s

  defp describe({:state, %{state: state}}), do: "state #{state}"
  defp describe({:steps, _}), do: "a steps update"
  defp describe({:log, _body, _bytes, count}), do: "#{count} log lines"

  defp backoff(s, attempt),
    do: Backoff.delay(attempt, s.cfg.backoff_min_ms, s.cfg.backoff_max_ms)

  defp wake(%{wake: nil} = s, at) do
    %{s | wake: {Process.send_after(self(), :wake, max(at - now(), 0)), at}}
  end

  defp wake(%{wake: {ref, current}} = s, at) when at < current do
    Process.cancel_timer(ref)
    wake(%{s | wake: nil}, at)
  end

  defp wake(s, _at), do: s

  # Logs

  defp encode_line(line) do
    {text, _truncated} = line |> Map.get(:text, "") |> Text.scrub() |> Text.cut(@max_text)

    %{t: line[:t], step_ref: line[:step_ref], text: text}
    |> Jason.encode_to_iodata!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp marker(count) do
    encode_line(%{
      t: System.system_time(:millisecond),
      step_ref: nil,
      text: "[crew-guest: #{count} log lines dropped while the guest API couldn't be reached]"
    })
  end

  # Takes the next batch: the marker for any lines dropped since the last
  # one, then lines up to the request size (always at least one). Its
  # count includes the marker's, so a batch that's dropped in turn carries
  # the earlier loss forward.
  defp take_batch(s) do
    carried = s.dropped
    head = if carried > 0, do: [marker(carried)], else: []
    limit = s.cfg.max_request_bytes - IO.iodata_length(head)
    {lines, bytes, logs} = take(s.logs, limit, [], 0)
    body = head ++ Enum.reverse(lines)
    item = {:log, body, IO.iodata_length(body), length(lines) + carried}
    {item, %{s | logs: logs, log_bytes: s.log_bytes - bytes, dropped: 0}}
  end

  defp take(q, limit, acc, bytes) do
    case :queue.peek(q) do
      {:value, line} when acc == [] or bytes + byte_size(line) <= limit ->
        take(:queue.drop(q), limit, [line | acc], bytes + byte_size(line))

      _ ->
        {acc, bytes, q}
    end
  end

  # Drops the oldest queued lines while everything held is over the buffer.
  defp trim(s) do
    held = s.log_bytes + item_bytes(s.log.item) + steps_bytes(s.steps)

    if held > s.cfg.buffer_bytes and not :queue.is_empty(s.logs) do
      {{:value, line}, logs} = :queue.out(s.logs)
      trim(%{s | logs: logs, log_bytes: s.log_bytes - byte_size(line), dropped: s.dropped + 1})
    else
      s
    end
  end

  defp item_bytes({:log, _body, bytes, _count}), do: bytes
  defp item_bytes(_item), do: 0

  defp steps_bytes({_body, bytes}), do: bytes
  defp steps_bytes(nil), do: 0

  # Steps

  # The guest API takes at most 256 KiB of steps. Long names are cut
  # first, then steps dropped from the end.
  defp fit_steps(steps, cfg) do
    steps = Enum.take(steps, CrewProtocol.Guest.max_steps())

    case encoded_size(steps) do
      size when size <= cfg.max_steps_bytes ->
        {%{steps: steps}, size}

      _ ->
        steps = Enum.map(steps, &short_name/1)
        drop_until_fits(steps, length(steps), cfg.max_steps_bytes)
    end
  end

  defp drop_until_fits(steps, n, max) do
    steps = Enum.take(steps, n)
    size = encoded_size(steps)

    if size <= max or n <= 1,
      do: {%{steps: steps}, size},
      else: drop_until_fits(steps, n - 10, max)
  end

  defp short_name(%{name: name} = step) when is_binary(name),
    do: %{step | name: elem(Text.cut(name, 64), 0)}

  defp short_name(step), do: step

  defp encoded_size(steps), do: IO.iodata_length(Jason.encode_to_iodata!(%{steps: steps}))

  # Flushing

  defp reply_flushers(%{flushers: []} = s), do: s

  defp reply_flushers(s) do
    if idle?(s) do
      Enum.each(s.flushers, &GenServer.reply(&1, :ok))
      %{s | flushers: []}
    else
      s
    end
  end

  defp idle?(s) do
    :queue.is_empty(s.states) and s.steps == nil and
      (s.logs_closed or (:queue.is_empty(s.logs) and s.dropped == 0)) and
      s.main.task == nil and s.log.task == nil and s.main.item == nil and s.log.item == nil
  end

  defp now, do: System.monotonic_time(:millisecond)
end
