defmodule CrewGuest.Pages do
  @moduledoc """
  Live log capture from the runner's log pages (§16.2).

  The runner's `PagingLogger` writes each step's console output to
  `_diag/pages/{timelineId}_{timelineRecordId}_{n}.log`, one
  `<UTC ISO-8601 timestamp> <message>` per line, rolling over to page
  `n + 1` at 8 MB. Finished pages are uploaded and then deleted.

  So each page is opened as soon as it appears (on the watcher's event, or
  the next directory scan if an event is missed), and read from that open
  descriptor until it's done: a deleted file stays readable through it,
  so the uploader can't race the reader. A page is done when the next page
  of its record appears, when it's been deleted, or at `finish/1` (the job
  has ended). Pages are followed in order of `n` within each record.

  Lines are handed to `:on_lines` as `%{t, step_ref, text}`, with `t` in
  Unix milliseconds. `:on_activity` gets `(record_id, first_t, last_t)` for
  each record that had lines, which feeds the page-order step fallback.
  """

  use GenServer

  require Logger

  alias CrewGuest.StepRef
  alias CrewProtocol.Text

  @max_line 65_536
  @chunk 65_536
  # The most read from one page per tick, so one busy step can't starve
  # the others. A done page is always read to its end.
  @tick_budget 4 * 1024 * 1024
  @bom <<0xEF, 0xBB, 0xBF>>
  @name ~r/\A([^_]+)_(.+)_(\d+)\.log\z/

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}

  @doc "Reads every open page to its end, emits what's left and closes them."
  def finish(server, timeout \\ 5_000), do: GenServer.call(server, :finish, timeout)

  @doc "Parses a page's file name."
  @spec parse_name(String.t()) :: {:ok, %{record: String.t(), n: pos_integer()}} | :error
  def parse_name(name) do
    case Regex.run(@name, name) do
      [_, _timeline, record, n] -> {:ok, %{record: record, n: String.to_integer(n)}}
      nil -> :error
    end
  end

  @doc """
  Splits a page line into `{t, text}`. A line without a timestamp prefix
  (part of a message that had a newline in it) keeps `last_t`.
  """
  @spec parse_line(binary(), integer() | nil) :: {integer() | nil, binary()}
  def parse_line(
        <<_::binary-4, "-", _::binary-2, "-", _::binary-2, "T", _::binary>> = line,
        last_t
      ) do
    {stamp, text} =
      case :binary.split(line, " ") do
        [stamp, text] -> {stamp, text}
        [stamp] -> {stamp, ""}
      end

    case DateTime.from_iso8601(stamp) do
      {:ok, dt, _offset} -> {DateTime.to_unix(dt, :millisecond), text}
      {:error, _} -> {last_t, line}
    end
  end

  def parse_line(line, last_t), do: {last_t, line}

  # Server

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    _ = File.mkdir_p(dir)
    # A watcher that dies only means scanning; restarting this process
    # would read every open page again from the start.
    Process.flag(:trap_exit, true)

    state = %{
      dir: dir,
      on_lines: Keyword.fetch!(opts, :on_lines),
      on_activity: Keyword.get(opts, :on_activity, fn _record, _first, _last -> :ok end),
      tick_ms: Keyword.get(opts, :tick_ms, 100),
      watcher: start_watcher(dir),
      # name => page, for pages that are open
      pages: %{},
      # names already handled (open or done), so a scan doesn't reopen them
      known: MapSet.new(),
      finished: false
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{finished: true} = s), do: {:noreply, s}

  def handle_info(:tick, s) do
    s = s |> scan() |> pump(false)
    Process.send_after(self(), :tick, s.tick_ms)
    {:noreply, s}
  end

  def handle_info({:file_event, _watcher, :stop}, s), do: {:noreply, %{s | watcher: nil}}

  def handle_info({:EXIT, watcher, _reason}, %{watcher: watcher} = s) when watcher != nil,
    do: {:noreply, %{s | watcher: nil}}

  def handle_info({:file_event, _watcher, {path, _events}}, %{finished: false} = s) do
    name = Path.basename(path)

    # A new page means a scan, not just opening that one, so a record's
    # earlier pages are always open before a later one is read.
    if MapSet.member?(s.known, name) or parse_name(name) == :error do
      {:noreply, s}
    else
      {:noreply, s |> scan() |> pump(false)}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_call(:finish, _from, s) do
    s = s |> scan() |> pump(true)
    {:reply, :ok, %{s | finished: true}}
  end

  # Scanning and opening

  defp scan(s) do
    case File.ls(s.dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&MapSet.member?(s.known, &1))
        |> Enum.filter(&match?({:ok, _}, parse_name(&1)))
        |> Enum.reduce(s, &open_page(&2, &1))

      {:error, _} ->
        s
    end
  end

  defp open_page(s, name) do
    {:ok, %{record: record, n: n}} = parse_name(name)
    path = Path.join(s.dir, name)

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        page = %{
          name: name,
          path: path,
          io: io,
          record: record,
          n: n,
          ref: StepRef.from(record),
          buf: "",
          fresh: true,
          skipping: false,
          last_t: nil
        }

        %{s | pages: Map.put(s.pages, name, page), known: MapSet.put(s.known, name)}

      # Not there (yet, or any more). An event can name a page before it
      # exists (FSEvents replays recent ones), so the name isn't marked
      # known, and the next event or scan tries again. One that's already
      # been deleted won't be listed again: its lines are lost.
      {:error, :enoent} ->
        s

      {:error, reason} ->
        Logger.warning("crew-guest: couldn't open log page #{name}: #{inspect(reason)}")
        %{s | known: MapSet.put(s.known, name)}
    end
  end

  # Reading

  defp pump(s, final?) do
    {s, lines} =
      s.pages
      |> Map.values()
      |> Enum.group_by(& &1.record)
      |> Enum.reduce({s, []}, fn {record, pages}, {s, acc} ->
        {s, lines} = follow(s, Enum.sort_by(pages, & &1.n), final?, [])
        if lines != [], do: activity(s, record, lines)
        {s, [lines | acc]}
      end)

    case lines |> Enum.reverse() |> List.flatten() do
      [] ->
        s

      lines ->
        s.on_lines.(lines)
        s
    end
  end

  # Reads a record's pages lowest n first. A page with a later page after
  # it, or one that's been deleted, is read to its end and closed.
  defp follow(s, [], _final?, acc), do: {s, acc |> Enum.reverse() |> List.flatten()}

  defp follow(s, [page | rest], final?, acc) do
    if final? or rest != [] or not File.exists?(page.path) do
      {page, lines} = read(page, :infinity)
      lines = lines ++ flush(page)
      File.close(page.io)
      follow(%{s | pages: Map.delete(s.pages, page.name)}, rest, final?, [lines | acc])
    else
      {page, lines} = read(page, @tick_budget)
      follow(put_in(s.pages[page.name], page), [], final?, [lines | acc])
    end
  end

  defp read(page, budget, acc \\ [])

  defp read(page, budget, acc) when is_integer(budget) and budget <= 0,
    do: {page, acc |> Enum.reverse() |> List.flatten()}

  defp read(page, budget, acc) do
    case :file.read(page.io, @chunk) do
      {:ok, data} ->
        {page, lines} = feed(page, data)
        budget = if budget == :infinity, do: budget, else: budget - byte_size(data)
        read(page, budget, [lines | acc])

      :eof ->
        {page, acc |> Enum.reverse() |> List.flatten()}

      {:error, reason} ->
        Logger.warning("crew-guest: couldn't read log page #{page.name}: #{inspect(reason)}")
        {page, acc |> Enum.reverse() |> List.flatten()}
    end
  end

  defp feed(%{fresh: true} = page, data) do
    data =
      if String.starts_with?(data, @bom),
        do: binary_part(data, 3, byte_size(data) - 3),
        else: data

    feed(%{page | fresh: false}, data)
  end

  defp feed(%{skipping: true} = page, data) do
    case :binary.match(data, "\n") do
      :nomatch ->
        {page, []}

      {pos, 1} ->
        feed(%{page | skipping: false}, binary_part(data, pos + 1, byte_size(data) - pos - 1))
    end
  end

  defp feed(page, data) do
    [partial | complete] = (page.buf <> data) |> :binary.split("\n", [:global]) |> Enum.reverse()
    {page, lines} = Enum.reduce(Enum.reverse(complete), {page, []}, &line/2)

    if byte_size(partial) > @max_line do
      {cut, _} = Text.cut(partial, @max_line)
      {page, lines} = line(cut, {page, lines})
      {%{page | buf: "", skipping: true}, Enum.reverse(lines)}
    else
      {%{page | buf: partial}, Enum.reverse(lines)}
    end
  end

  defp flush(%{buf: ""}), do: []

  defp flush(page) do
    {_page, [line]} = line(page.buf, {page, []})
    [line]
  end

  defp line(raw, {page, acc}) do
    raw = if String.ends_with?(raw, "\r"), do: binary_part(raw, 0, byte_size(raw) - 1), else: raw
    {t, text} = parse_line(raw, page.last_t)
    t = t || System.system_time(:millisecond)
    {%{page | last_t: t}, [%{t: t, step_ref: page.ref, text: text} | acc]}
  end

  defp activity(s, record, lines) do
    s.on_activity.(record, hd(lines).t, List.last(lines).t)
  end

  # The watcher only speeds up opening new pages: the scan on every tick
  # finds anything it misses, so crew-guest works without one.
  defp start_watcher(dir) do
    opts = [dirs: [dir]] ++ backend_opts()

    case FileSystem.start_link(opts) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      other ->
        Logger.warning("crew-guest: no file watcher on #{dir} (#{inspect(other)}), scanning only")
        nil
    end
  end

  defp backend_opts do
    case :os.type() do
      {:unix, :darwin} -> [latency: 0.0, no_defer: true]
      _ -> [recursive: false]
    end
  end
end
