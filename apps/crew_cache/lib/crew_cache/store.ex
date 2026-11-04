defmodule CrewCache.Store do
  @moduledoc """
  The content-addressed store (§15.2): blobs and manifests alike under
  `<dir>/blobs/sha256/<2>/<64>`, with an SQLite index (`<dir>/index.db`)
  of each object's size, kind, media type, upstream host, repository and
  last access.

  An object is the same bytes whichever repository it came through, so
  it's stored once, under the host and repository that first fetched it.
  A purge by repository removes the objects recorded under it; another
  repository sharing one fetches it again.

  Lookups read an ETS copy of the index, so serving doesn't queue behind
  writes. Commits, touches, purges and evictions go through this process.

  **The quota** (§15.3): past 95% of `max_bytes`, the least recently
  accessed objects are evicted until the store is at 85%. Files being
  read when they're evicted stay readable until closed.

  The store trusts what it's given: `CrewCache.Fetcher` verifies digests
  before it commits.
  """
  use GenServer

  require Logger

  alias Exqlite.Sqlite3

  @table __MODULE__

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
  def touch(digest), do: GenServer.cast(__MODULE__, {:touch, digest})

  @doc "Move a verified temporary file into the store."
  @spec commit(Path.t(), digest, meta) :: :ok | {:error, term}
  def commit(tmp, digest, meta),
    do: GenServer.call(__MODULE__, {:commit, tmp, digest, meta}, 60_000)

  @doc "Remove `:all`, `{:host, host}` or `{:repo, host, repo}`."
  def purge(scope), do: GenServer.call(__MODULE__, {:purge, scope}, 120_000)

  @doc "Evict least recently accessed objects until the store holds at most `target` bytes."
  def evict_to(target), do: GenServer.call(__MODULE__, {:evict_to, target}, 120_000)

  def usage, do: GenServer.call(__MODULE__, :usage)

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
    state = %{dir: dir, db: db, max: max, bytes: 0, clock: 0}
    {:ok, load(state)}
  end

  # Rows whose file has gone are dropped (a crash between the insert and
  # the rename, or someone tidying by hand).
  defp load(state) do
    rows = query(state.db, "SELECT digest, kind, media_type, size, host, repo FROM objects", [])

    {present, missing} =
      Enum.split_with(rows, fn [digest | _] -> File.regular?(path(state.dir, digest)) end)

    for [digest | _] <- missing,
        do: exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])

    for [digest, kind, media_type, size, host, repo] <- present do
      :ets.insert(@table, {digest, meta(state.dir, digest, kind, media_type, size, host, repo)})
    end

    [[clock]] = query(state.db, "SELECT COALESCE(MAX(last_access), 0) FROM objects", [])
    %{state | bytes: present |> Enum.map(&Enum.at(&1, 3)) |> Enum.sum(), clock: clock}
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
  def handle_call({:commit, tmp, digest, meta}, _from, state) do
    if :ets.member(@table, digest) do
      File.rm(tmp)
      {:reply, :ok, state}
    else
      dest = path(state.dir, digest)
      File.mkdir_p!(Path.dirname(dest))
      {now, state} = tick(state)

      exec(
        state.db,
        "INSERT OR REPLACE INTO objects VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
        [digest, to_string(meta.kind), meta.media_type, meta.size, meta.host, meta.repo, now]
      )

      case File.rename(tmp, dest) do
        :ok ->
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
          state = enforce_quota(%{state | bytes: state.bytes + meta.size})
          {:reply, :ok, state}

        {:error, reason} = error ->
          exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])
          Logger.error("couldn't commit #{digest}: #{inspect(reason)}")
          {:reply, error, state}
      end
    end
  end

  def handle_call({:purge, scope}, _from, state) do
    {where, args} =
      case scope do
        :all -> {"1 = 1", []}
        {:host, host} -> {"host = ?1", [host]}
        {:repo, host, repo} -> {"host = ?1 AND repo = ?2", [host, repo]}
      end

    rows = query(state.db, "SELECT digest, size FROM objects WHERE #{where}", args)
    {state, bytes} = remove(state, rows)
    {:reply, {:ok, %{removed: length(rows), bytes: bytes}}, state}
  end

  def handle_call({:evict_to, target}, _from, state) do
    {state, count, bytes} = evict(state, max(target, 0))
    {:reply, {:ok, %{evicted: count, bytes: bytes, store_bytes: state.bytes}}, state}
  end

  def handle_call(:usage, _from, state) do
    by_host =
      for [host, bytes] <-
            query(state.db, "SELECT host, SUM(size) FROM objects GROUP BY host", []),
          into: %{},
          do: {host, bytes}

    {:reply,
     %{
       bytes: state.bytes,
       objects: :ets.info(@table, :size),
       max_bytes: state.max,
       by_host: by_host
     }, state}
  end

  @impl true
  def handle_cast({:touch, digest}, state) do
    {now, state} = tick(state)
    exec(state.db, "UPDATE objects SET last_access = ?2 WHERE digest = ?1", [digest, now])

    {:noreply, state}
  end

  # Access times in microseconds, strictly increasing so the LRU order is
  # the order of accesses even within one clock tick.
  defp tick(state) do
    now = max(System.os_time(:microsecond), state.clock + 1)
    {now, %{state | clock: now}}
  end

  defp enforce_quota(%{bytes: bytes, max: max} = state) do
    if bytes > max * 0.95 do
      {state, count, freed} = evict(state, trunc(max * 0.85))
      Logger.info("store past 95%: evicted #{count} objects, #{freed} bytes")
      state
    else
      state
    end
  end

  defp evict(state, target, count \\ 0, freed \\ 0)

  defp evict(%{bytes: bytes} = state, target, count, freed) when bytes <= target,
    do: {state, count, freed}

  defp evict(state, target, count, freed) do
    sql = "SELECT digest, size FROM objects ORDER BY last_access, stored_at LIMIT 64"

    case query(state.db, sql, []) do
      [] ->
        {state, count, freed}

      rows ->
        victims = take_until(rows, state.bytes, target)
        {state, bytes} = remove(state, victims)
        CrewCache.Stats.evicted(length(victims))
        evict(state, target, count + length(victims), freed + bytes)
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
        File.rm(path(state.dir, digest))
        exec(state.db, "DELETE FROM objects WHERE digest = ?1", [digest])
        acc + size
      end)

    {%{state | bytes: state.bytes - bytes}, bytes}
  end

  # -- SQLite -------------------------------------------------------------------

  defp query(db, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end

  defp exec(db, sql, args) do
    query(db, sql, args)
    :ok
  end
end
