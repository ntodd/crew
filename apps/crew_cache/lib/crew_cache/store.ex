defmodule CrewCache.Store do
  @moduledoc """
  The content-addressed store (§15.2): blobs and manifests alike under
  `<dir>/blobs/sha256/<2>/<64>`, with an SQLite index (`<dir>/index.db`)
  of each object's size, kind, media type, upstream host, repository and
  last access.

  An object is the same bytes whichever repository it came through, so
  it's stored once, under the host and repository that first fetched it.
  A purge by repository removes the objects recorded under it; another
  repository sharing one fetches it again. Bytes first stored as a blob
  become a manifest when they're committed as one.

  Lookups read an ETS copy of the index, so serving doesn't queue behind
  writes. Touches go to ETS too and are written in batches (every 2 s,
  and before anything that orders by them). Commits, reservations,
  purges and evictions go through this process.

  **The quota** (§15.3): past 95% of `max_bytes`, counting space
  reserved by downloads in flight (`reserve/2`), the least recently
  accessed objects are evicted until the store is at 85%. Files being
  read when they're evicted stay readable until closed.

  **At start** the index is checked against the files: rows whose file
  is missing or the wrong size go (a crash before the data was durable),
  and so do files no row knows. Temporary files older than an hour are
  swept every 10 minutes.

  The store trusts what it's given: `CrewCache.Fetcher` verifies digests
  before it commits.
  """
  use GenServer

  require Logger

  alias Exqlite.Sqlite3

  @table __MODULE__
  @touches :crew_cache_touches
  @flush_ms 2_000
  @sweep_ms 10 * 60_000
  @tmp_max_age_s 3600

  @type digest :: String.t()
  @type meta :: %{
          kind: :blob | :manifest,
          media_type: String.t() | nil,
          host: String.t(),
          repo: String.t(),
          size: non_neg_integer
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where `digest` (`sha256:<hex>`) lives in the store."
  def path(dir, "sha256:" <> hex),
    do: Path.join([dir, "blobs", "sha256", binary_part(hex, 0, 2), hex])

  @doc "A fresh temporary file name, inside the store's filesystem so a commit is a rename."
  def tmp_path do
    dir = :persistent_term.get({__MODULE__, :dir})
    Path.join([dir, "tmp", Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)])
  end

  @spec lookup(digest) :: {:ok, map} | :error
  def lookup(digest) do
    case :ets.lookup(@table, digest) do
      [{^digest, meta}] -> {:ok, meta}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Record an access, for the LRU."
  def touch(digest) do
    :ets.insert(@touches, {digest, System.os_time(:microsecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Hold `size` more bytes for a download, for `owner` (the calling
  process by default), evicting to make room. `:full` when it can't
  fit. The hold lasts until the owner commits, releases or exits.
  """
  def reserve(owner \\ self(), size),
    do: GenServer.call(__MODULE__, {:reserve, owner, size}, 60_000)

  @doc "Drop what `owner` holds."
  def release(owner \\ self()), do: GenServer.cast(__MODULE__, {:release, owner})

  @doc "Move a verified temporary file into the store."
  @spec commit(Path.t(), digest, meta) :: :ok | {:error, term}
  def commit(tmp, digest, meta) do
    GenServer.call(__MODULE__, {:commit, tmp, digest, meta}, 60_000)
  catch
    :exit, reason -> {:error, {:store, reason}}
  end

  @doc "Remove `:all`, `{:host, host}` or `{:repo, host, repo}`."
  def purge(scope), do: GenServer.call(__MODULE__, {:purge, scope}, 120_000)

  @doc "Evict least recently accessed objects until the store holds at most `target` bytes."
  def evict_to(target), do: GenServer.call(__MODULE__, {:evict_to, target}, 120_000)

  def usage, do: GenServer.call(__MODULE__, :usage)

  @doc false
  def sweep_tmp, do: GenServer.call(__MODULE__, :sweep_tmp)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    max = Keyword.fetch!(opts, :max_bytes)

    File.mkdir_p!(Path.join([dir, "blobs", "sha256"]))
    File.rm_rf!(Path.join(dir, "tmp"))
    File.mkdir_p!(Path.join(dir, "tmp"))
    :persistent_term.put({__MODULE__, :dir}, dir)

    {:ok, db} = Sqlite3.open(Path.join(dir, "index.db"))

    :ok =
      Sqlite3.execute(db, """
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS objects (
        digest TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        media_type TEXT,
        size INTEGER NOT NULL,
        host TEXT NOT NULL,
        repo TEXT NOT NULL,
        stored_at INTEGER NOT NULL,
        last_access INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS objects_last_access ON objects (last_access);
      CREATE INDEX IF NOT EXISTS objects_host_repo ON objects (host, repo);
      """)

    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ets.new(@touches, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :flush, @flush_ms)
    Process.send_after(self(), :sweep, @sweep_ms)

    state = %{dir: dir, db: db, max: max, bytes: 0, clock: 0, reserved: %{}}
    {:ok, load(state)}
  end

  defp load(state) do
    {:ok, rows} =
      query(state.db, "SELECT digest, kind, media_type, size, host, repo FROM objects", [])

    {present, bad} =
      Enum.split_with(rows, fn [digest, _, _, size | _] ->
        match?({:ok, %{type: :regular, size: ^size}}, File.stat(path(state.dir, digest)))
      end)

    for [digest | _] <- bad do
      File.rm(path(state.dir, digest))
      exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])
    end

    for [digest, kind, media_type, size, host, repo] <- present do
      :ets.insert(@table, {digest, meta(state.dir, digest, kind, media_type, size, host, repo)})
    end

    remove_orphans(state.dir)
    {:ok, [[clock]]} = query(state.db, "SELECT COALESCE(MAX(last_access), 0) FROM objects", [])
    %{state | bytes: present |> Enum.map(&Enum.at(&1, 3)) |> Enum.sum(), clock: clock}
  end

  defp remove_orphans(dir) do
    for file <- Path.wildcard(Path.join([dir, "blobs", "sha256", "*", "*"])),
        not :ets.member(@table, "sha256:" <> Path.basename(file)),
        do: File.rm(file)
  end

  defp meta(dir, digest, kind, media_type, size, host, repo) do
    %{
      digest: digest,
      path: path(dir, digest),
      kind: String.to_existing_atom(kind),
      media_type: media_type,
      size: size,
      host: host,
      repo: repo
    }
  end

  @impl true
  def handle_call({:reserve, pid, size}, _from, state) do
    reserved = reserved_total(state)

    if reserved + size > state.max * 0.95 do
      {:reply, :full, state}
    else
      state = add_reservation(state, pid, size)
      {:reply, :ok, enforce_quota(state)}
    end
  end

  # The committer's reservation becomes the object's bytes.
  def handle_call({:commit, tmp, digest, meta}, {pid, _}, state) do
    state = drop_reservation(state, pid)

    case lookup(digest) do
      {:ok, %{kind: :blob} = existing} when meta.kind == :manifest ->
        File.rm(tmp)

        exec(
          state.db,
          "UPDATE objects SET kind = 'manifest', media_type = ?2 WHERE digest = ?1",
          [
            digest,
            meta.media_type
          ]
        )

        :ets.insert(@table, {digest, %{existing | kind: :manifest, media_type: meta.media_type}})
        {:reply, :ok, state}

      {:ok, _} ->
        File.rm(tmp)
        {:reply, :ok, state}

      :error ->
        {reply, state} = insert(state, tmp, digest, meta)
        {:reply, reply, state}
    end
  end

  def handle_call({:purge, scope}, _from, state) do
    {where, args} =
      case scope do
        :all -> {"1 = 1", []}
        {:host, host} -> {"host = ?1", [host]}
        {:repo, host, repo} -> {"host = ?1 AND repo = ?2", [host, repo]}
      end

    {:ok, rows} = query(state.db, "SELECT digest, size FROM objects WHERE #{where}", args)
    {state, bytes} = remove(state, rows)
    {:reply, {:ok, %{removed: length(rows), bytes: bytes}}, state}
  end

  def handle_call({:evict_to, target}, _from, state) do
    {state, count, bytes} = evict(state, max(target, 0))
    {:reply, {:ok, %{evicted: count, bytes: bytes, store_bytes: state.bytes}}, state}
  end

  def handle_call(:usage, _from, state) do
    {:ok, rows} = query(state.db, "SELECT host, SUM(size) FROM objects GROUP BY host", [])

    {:reply,
     %{
       bytes: state.bytes,
       reserved: reserved_total(state),
       objects: :ets.info(@table, :size),
       max_bytes: state.max,
       by_host: Map.new(rows, fn [host, bytes] -> {host, bytes} end)
     }, state}
  end

  def handle_call(:sweep_tmp, _from, state), do: {:reply, sweep(state), state}

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, flush_touches(state)}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    sweep(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case Map.pop(state.reserved, pid) do
      {{^ref, _size}, reserved} -> {:noreply, %{state | reserved: reserved}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, drop_reservation(state, pid)}

  defp drop_reservation(state, pid) do
    case Map.pop(state.reserved, pid) do
      {{ref, _size}, reserved} ->
        Process.demonitor(ref, [:flush])
        %{state | reserved: reserved}

      {nil, _} ->
        state
    end
  end

  defp insert(state, tmp, digest, meta) do
    dest = path(state.dir, digest)
    File.mkdir_p!(Path.dirname(dest))
    {now, state} = tick(state)

    insert =
      exec(state.db, "INSERT OR REPLACE INTO objects VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)", [
        digest,
        to_string(meta.kind),
        meta.media_type,
        meta.size,
        meta.host,
        meta.repo,
        now
      ])

    with :ok <- insert, :ok <- File.rename(tmp, dest) do
      row =
        meta(
          state.dir,
          digest,
          to_string(meta.kind),
          meta.media_type,
          meta.size,
          meta.host,
          meta.repo
        )

      :ets.insert(@table, {digest, row})
      {:ok, enforce_quota(%{state | bytes: state.bytes + meta.size})}
    else
      {:error, reason} = error ->
        exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])
        File.rm(tmp)
        Logger.error("couldn't commit #{digest}: #{inspect(reason)}")
        {error, state}
    end
  end

  # -- reservations ----------------------------------------------------------------

  defp add_reservation(state, pid, size) do
    entry =
      case Map.fetch(state.reserved, pid) do
        {:ok, {ref, held}} -> {ref, held + size}
        :error -> {Process.monitor(pid), size}
      end

    %{state | reserved: Map.put(state.reserved, pid, entry)}
  end

  defp reserved_total(state),
    do: state.reserved |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  # -- the quota -----------------------------------------------------------------

  # Access times in microseconds, strictly increasing so the LRU order is
  # the order of accesses even within one clock tick.
  defp tick(state) do
    now = max(System.os_time(:microsecond), state.clock + 1)
    {now, %{state | clock: now}}
  end

  defp flush_touches(state) do
    touches = :ets.tab2list(@touches) |> Enum.sort_by(&elem(&1, 1))
    for {digest, _} <- touches, do: :ets.delete(@touches, digest)

    Enum.reduce(touches, state, fn {digest, _}, state ->
      {now, state} = tick(state)
      exec(state.db, "UPDATE objects SET last_access = ?2 WHERE digest = ?1", [digest, now])
      state
    end)
  end

  defp enforce_quota(%{max: max} = state) do
    if state.bytes + reserved_total(state) > max * 0.95 do
      target = max(trunc(max * 0.85) - reserved_total(state), 0)
      {state, count, freed} = evict(state, target)
      if count > 0, do: Logger.info("store past 95%: evicted #{count} objects, #{freed} bytes")
      state
    else
      state
    end
  end

  defp evict(state, target, count \\ 0, freed \\ 0)

  defp evict(%{bytes: bytes} = state, target, count, freed) when bytes <= target,
    do: {state, count, freed}

  defp evict(state, target, count, freed) do
    state = flush_touches(state)
    sql = "SELECT digest, size FROM objects ORDER BY last_access, stored_at LIMIT 64"

    case query(state.db, sql, []) do
      {:ok, []} ->
        {state, count, freed}

      {:ok, rows} ->
        victims = take_until(rows, state.bytes, target)
        {state, bytes} = remove(state, victims)
        CrewCache.Stats.evicted(length(victims))
        evict(state, target, count + length(victims), freed + bytes)

      {:error, _} ->
        {state, count, freed}
    end
  end

  # The oldest rows whose removal brings `left` down to `target`.
  defp take_until([], _left, _target), do: []
  defp take_until(_rows, left, target) when left <= target, do: []

  defp take_until([[_, size] = row | rest], left, target),
    do: [row | take_until(rest, left - size, target)]

  defp remove(state, rows) do
    bytes =
      Enum.reduce(rows, 0, fn [digest, size], acc ->
        :ets.delete(@table, digest)
        :ets.delete(@touches, digest)
        File.rm(path(state.dir, digest))
        exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])
        acc + size
      end)

    {%{state | bytes: state.bytes - bytes}, bytes}
  end

  defp sweep(state) do
    cutoff = System.os_time(:second) - @tmp_max_age_s

    for file <- Path.wildcard(Path.join([state.dir, "tmp", "*"])),
        {:ok, %{mtime: mtime}} <- [File.stat(file, time: :posix)],
        mtime < cutoff,
        do: File.rm(file)

    :ok
  end

  # -- SQLite -------------------------------------------------------------------

  # Errors come back rather than crash the store: a full disk shouldn't
  # take the registry and DNS down with it.
  defp query(db, sql, args) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, args), do: Sqlite3.fetch_all(db, stmt)
      after
        Sqlite3.release(db, stmt)
      end
    end
  end

  defp exec(db, sql, args) do
    case query(db, sql, args) do
      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.error("index write failed: #{inspect(reason)}")
        error
    end
  end
end
