defmodule Crew.Logs do
  @moduledoc """
  Job logs (§16.2, §16.3).

  - **Live capture, per VM:** `${CREW_LOG_DIR}/vm/<vm_id>/live.ndjson`, one
    `{n, t, step_ref, text}` object per line, written by
    `Crew.Logs.Stream`, and broadcast on `vm:<id>:log` as it arrives. A
    job's live log is its VM's.
  - **GitHub's log, per job:** `${CREW_LOG_DIR}/job/<job_id>/github.ndjson`,
    the authoritative one once it exists (`Crew.Jobs.FetchLog`).
  - **Segments:** a `log_segments` row every 1000 lines, so a range read
    seeks straight to its place.

  Files stay uncompressed until retention deletes them, so offsets keep
  working.
  """
  import Ecto.Query

  alias Crew.{Metrics, Repo}
  alias Crew.Logs.Stream, as: LogStream
  alias Crew.VMs.VM

  @max_lines 5000
  @max_bytes 1_048_576
  @max_hits 10_000
  @search_ms 2_000

  def child_spec(_),
    do: %{
      id: Crew.Logs.Supervisor,
      start:
        {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: Crew.Logs.Supervisor]]},
      type: :supervisor
    }

  def dir, do: Application.get_env(:crew, :log_dir, "/var/lib/crew/logs")

  @doc "The file of a VM's live log or a job's GitHub log."
  def path(:vm, vm_id), do: Path.join([dir(), "vm", vm_id, "live.ndjson"])
  def path(:job, job_id), do: Path.join([dir(), "job", job_id, "github.ndjson"])

  def topic(vm_id), do: "vm:#{vm_id}:log"

  def index_path(source, owner_id),
    do: Path.join(Path.dirname(path(source, owner_id)), "index.json")

  @doc "A log's index (`Crew.Logs.Index`): step starts, groups, annotations."
  def index(source, owner_id) do
    case File.read(index_path(source, owner_id)) do
      {:ok, json} -> Crew.Logs.Index.decode(json)
      _ -> Crew.Logs.Index.new()
    end
  end

  @doc "Subscribes to a VM's log lines (`{:log_lines, vm_id, lines}`), steps and metrics."
  def subscribe(vm_id), do: Phoenix.PubSub.subscribe(Crew.PubSub, topic(vm_id))
  def unsubscribe(vm_id), do: Phoenix.PubSub.unsubscribe(Crew.PubSub, topic(vm_id))

  # -- agent events -------------------------------------------------------------

  @doc "`vm.log`, `vm.log.gone`, `vm.steps` and `vm.metrics` for one of the box's VMs."
  def handle_agent_event(%VM{} = vm, "vm.log", payload),
    do: LogStream.deliver(vm.id, {:log, payload})

  def handle_agent_event(%VM{} = vm, "vm.log.gone", payload),
    do: LogStream.deliver(vm.id, {:gone, payload})

  def handle_agent_event(%VM{} = vm, "vm.steps", %{steps: steps}) do
    path = Path.join([dir(), "vm", vm.id, "steps.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(steps))
    Phoenix.PubSub.broadcast(Crew.PubSub, topic(vm.id), {:vm_steps, vm.id})
    :ok
  end

  def handle_agent_event(%VM{} = vm, "vm.metrics", payload), do: Metrics.record_vm(vm, payload)
  def handle_agent_event(_vm, _type, _payload), do: :ok

  @doc "The guest's steps for a VM, as it last reported them."
  def steps(vm_id) do
    with {:ok, body} <- File.read(Path.join([dir(), "vm", vm_id, "steps.json"])),
         {:ok, steps} when is_list(steps) <- Jason.decode(body) do
      Enum.map(steps, fn s ->
        %{
          ref: s["ref"],
          name: s["name"],
          number: s["number"],
          status: s["status"],
          conclusion: s["conclusion"],
          started_at: s["started_at"],
          completed_at: s["completed_at"]
        }
      end)
    else
      _ -> []
    end
  end

  # -- segments ---------------------------------------------------------------------

  @doc false
  def put_segment(source, owner_id, first_n, last_n, offset, len) do
    Repo.insert_all(
      "log_segments",
      [
        %{
          source: to_string(source),
          owner_id: dump(owner_id),
          first_n: first_n,
          last_n: last_n,
          byte_offset: offset,
          byte_len: len
        }
      ],
      on_conflict: :nothing
    )
  end

  @doc false
  # Where the segment being written starts: after the last full one.
  def open_segment(source, owner_id) do
    case last_segment(source, owner_id) do
      nil -> {1, 0}
      {_first, last, offset, len} -> {last + 1, offset + len}
    end
  end

  defp last_segment(source, owner_id) do
    Repo.one(
      from s in "log_segments",
        where: s.source == ^to_string(source) and s.owner_id == ^dump(owner_id),
        order_by: [desc: s.first_n],
        limit: 1,
        select: {s.first_n, s.last_n, s.byte_offset, s.byte_len}
    )
  end

  # Where to start reading for line `n`: the segment holding it, or the
  # end of the last full one.
  defp seek_for(source, owner_id, n) do
    Repo.one(
      from s in "log_segments",
        where:
          s.source == ^to_string(source) and s.owner_id == ^dump(owner_id) and s.first_n <= ^n,
        order_by: [desc: s.first_n],
        limit: 1,
        select: {s.first_n, s.last_n, s.byte_offset, s.byte_len}
    )
    |> case do
      nil -> 0
      {_first, last, offset, len} when last < n -> offset + len
      {_first, _last, offset, _len} -> offset
    end
  end

  # log_segments.owner_id is a UUID column, written schemaless.
  defp dump(id), do: Ecto.UUID.dump!(id)

  # -- GitHub's log (§16.3) ---------------------------------------------------------

  @stamp ~r/\A(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z) ?(.*)\z/s

  @doc """
  Stores GitHub's log for a job: one plain-text file of
  timestamp-prefixed lines, each assigned to a step by its timestamp
  against the API's steps. A line without a timestamp keeps the one
  before it. Written whole, then put in place.
  """
  def store_github(job, body, cut?) do
    steps =
      job.steps |> Enum.map(&step_window/1) |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.number)

    path = path(:job, job.id)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    {:ok, io} = :file.open(tmp, [:write, :raw, :binary])

    lines =
      body
      |> utf8()
      |> String.replace_prefix("\uFEFF", "")
      |> String.split(~r/\r?\n/)
      |> drop_trailing_empty()

    marker = if cut?, do: ["[the log was cut at #{div(byte_size(body), 1024)} KiB]"], else: []

    {n, size, segments, _t, index} =
      Enum.reduce(lines ++ marker, {0, 0, [], nil, Crew.Logs.Index.new()}, fn raw,
                                                                              {n, size, segs,
                                                                               last_t, index} ->
        {t, text} = parse_stamp(raw, last_t)
        line = %{n: n + 1, t: t, step_ref: step_for(steps, t), text: text}
        json = [Jason.encode_to_iodata!(line), ?\n]
        :ok = :file.write(io, json)
        new_size = size + IO.iodata_length(json)
        segs = if rem(n + 1, 1000) == 0, do: [{n + 1, new_size} | segs], else: segs
        {n + 1, new_size, segs, t, Crew.Logs.Index.add(index, [line])}
      end)

    :ok = :file.close(io)
    File.write!(index_path(:job, job.id), Crew.Logs.Index.encode(index))
    File.rename!(tmp, path)

    Repo.delete_all(
      from s in "log_segments", where: s.source == "job" and s.owner_id == ^dump(job.id)
    )

    ends = Enum.reverse(segments) ++ if(rem(n, 1000) != 0 or n == 0, do: [{n, size}], else: [])

    {_, _} =
      Enum.reduce(ends, {1, 0}, fn {last, offset_end}, {first, offset} ->
        if last >= first, do: put_segment(:job, job.id, first, last, offset, offset_end - offset)
        {last + 1, offset_end}
      end)

    :ok
  end

  # A cut at the size cap can split a character, and logs aren't always
  # valid UTF-8: what's stored is.
  defp utf8(body) do
    trimmed = trim_partial(body)
    if String.valid?(trimmed), do: trimmed, else: String.replace_invalid(trimmed)
  end

  # Drops a trailing incomplete UTF-8 sequence (at most 3 bytes).
  defp trim_partial(body) do
    Enum.find_value(0..min(3, byte_size(body)), body, fn k ->
      candidate = binary_part(body, 0, byte_size(body) - k)
      if String.valid?(candidate), do: candidate
    end)
  end

  defp drop_trailing_empty(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  defp parse_stamp(raw, last_t) do
    with [_, stamp, text] <- Regex.run(@stamp, raw),
         {:ok, at, _} <- DateTime.from_iso8601(stamp) do
      {DateTime.to_unix(at, :millisecond), text}
    else
      _ -> {last_t, raw}
    end
  end

  defp step_window(%{"number" => number, "started_at" => started} = step)
       when is_binary(started) do
    {:ok, from, _} = DateTime.from_iso8601(started)
    %{number: number, from: DateTime.to_unix(from, :millisecond), name: step["name"]}
  end

  defp step_window(_), do: nil

  # The step that had started by `t`, the latest one.
  defp step_for(_steps, nil), do: nil

  defp step_for(steps, t) do
    case steps |> Enum.filter(&(&1.from <= t)) |> List.last() do
      nil -> nil
      step -> "step-#{step.number}"
    end
  end

  # -- reads ----------------------------------------------------------------------------

  @doc "The last line number stored, or nil when there's none."
  # A log retention deleted has no lines, whatever the row says.
  def last_n(:vm, vm_id) do
    case Repo.one(from v in VM, where: v.id == ^vm_id, select: v.last_log_n) do
      n when is_integer(n) and n > 0 -> if File.exists?(path(:vm, vm_id)), do: n
      _ -> nil
    end
  end

  def last_n(:job, job_id) do
    case last_segment(:job, job_id) do
      {_, last, _, _} -> if File.exists?(path(:job, job_id)), do: last
      nil -> nil
    end
  end

  @doc """
  Lines `from..to` (inclusive), clamped to #{@max_lines} lines and
  #{div(@max_bytes, 1024)} KiB of text (§17.6).
  """
  def lines(source, owner_id, from, to) do
    from = max(from, 1)
    to = min(to, from + @max_lines - 1)
    path = path(source, owner_id)

    if to < from or not File.exists?(path) do
      []
    else
      {:ok, io} = :file.open(path, [:read, :raw, :binary, {:read_ahead, 64 * 1024}])

      try do
        {:ok, _} = :file.position(io, seek_for(source, owner_id, from))
        read(io, from, to, 0, [])
      after
        :file.close(io)
      end
    end
  end

  defp read(io, from, to, bytes, acc) do
    case :file.read_line(io) do
      {:ok, raw} ->
        line = decode(raw)

        cond do
          line == nil or line.n < from -> read(io, from, to, bytes, acc)
          line.n > to -> Enum.reverse(acc)
          acc != [] and bytes + byte_size(line.text) > @max_bytes -> Enum.reverse(acc)
          true -> read(io, from, to, bytes + byte_size(line.text), [line | acc])
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"n" => n, "text" => text} = l} ->
        %{n: n, t: l["t"], step_ref: l["step_ref"], text: text}

      _ ->
        nil
    end
  end

  @doc "Every line as plain text, for **Download raw** (§17.6)."
  def raw(source, owner_id) do
    path = path(source, owner_id)

    if File.exists?(path),
      do:
        path
        |> File.stream!(:line)
        |> Stream.map(&decode/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.map(&[&1.text, ?\n]),
      else: []
  end

  # -- search (§17.6) -------------------------------------------------------------------

  @doc """
  The numbers of the lines matching `q`, at most #{@max_hits}: plain text
  or a regex, with or without case, over the text without its ANSI
  escapes. Regexes run with PCRE's match limits, and the whole search in
  a task with a #{div(@search_ms, 1000)} s timeout.
  """
  def search(source, owner_id, q, opts \\ []) do
    with {:ok, match?} <- matcher(q, opts) do
      task = Task.async(fn -> scan(path(source, owner_id), match?) end)

      case Task.yield(task, @search_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, hits} -> {:ok, hits}
        _ -> {:error, "the search took too long"}
      end
    end
  end

  defp matcher(q, opts) when is_binary(q) and q != "" do
    caseless = not Keyword.get(opts, :case, false)

    if Keyword.get(opts, :regex, false) do
      case :re.compile(q, [:unicode | if(caseless, do: [:caseless], else: [])]) do
        {:ok, re} ->
          limits = [
            {:match_limit, 1_000_000},
            {:match_limit_recursion, 10_000},
            :report_errors,
            {:capture, :none}
          ]

          {:ok, fn text -> :re.run(text, re, limits) == :match end}

        {:error, {reason, _}} ->
          {:error, "bad regex: #{reason}"}
      end
    else
      needle = if caseless, do: String.downcase(q), else: q

      {:ok,
       fn text ->
         String.contains?(if(caseless, do: String.downcase(text), else: text), needle)
       end}
    end
  end

  defp matcher(_q, _opts), do: {:error, "nothing to search for"}

  defp scan(path, match?) do
    if File.exists?(path) do
      path
      |> File.stream!(:line, read_ahead: 256 * 1024)
      |> Stream.map(&decode/1)
      |> Stream.reject(&is_nil/1)
      |> Stream.filter(&match?.(strip_ansi(&1.text)))
      |> Stream.map(& &1.n)
      |> Enum.take(@max_hits)
    else
      []
    end
  end

  @ansi ~r/\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)|[@-Z\\-_])/

  @doc "Text without its escape sequences."
  def strip_ansi(text), do: String.replace(text, @ansi, "")
end
