defmodule CrewCache.Fetcher do
  @moduledoc """
  One upstream fetch of one object, shared by everyone who asks for it
  while it runs (§15.3: identical concurrent fetches are coalesced).
  Fetches are keyed by kind and digest, so a request for a digest as the
  wrong kind can't decide the outcome for the right one.

  The download runs in its own linked process, writing a temporary file
  in the store and hashing as it goes; it carries on if the clients go.
  Clients `open/1` the fetch and tail the file (`stream/3`), so the
  first byte reaches every client as soon as it's on disk. The last byte
  is held back until the digest is verified: a mismatch cuts every
  response short, so no client ever gets a complete wrong blob.

  **Progress** is a shared counter (`:atomics`) the download bumps. A
  client that has caught up parks, and gets one wake-up when there's
  more: a client that reads slowly never collects a mailbox of updates.

  **Space:** a download with a `Content-Length` reserves it in the store
  first (`CrewCache.Store.reserve/1`), so downloads in flight count
  against the quota; one that won't fit is refused (and the client goes
  upstream). At most `max_fetches` run at once.

  When the SHA-256 matches, the file is synced and committed and the
  fetch ends. When it doesn't, nothing is stored, the mismatch is
  counted, and the failed fetch stays registered for 30 seconds so
  requests get a 502 without asking the upstream again. Other failures
  end the fetch at once.

  Manifests use the same path but are small (at most 4 MiB): their
  clients wait for the verified commit and are served from the store.
  """
  use GenServer, restart: :temporary

  require Logger

  alias CrewCache.{Stats, Store, Upstream}

  @registry CrewCache.Fetcher.Registry
  @supervisor CrewCache.Fetcher.Supervisor
  @failed_linger_ms 30_000
  @manifest_max 4 * 1024 * 1024
  @idle_ms 60_000

  @type spec :: %{
          host: Upstream.host(),
          repo: String.t(),
          digest: String.t(),
          kind: :blob | :manifest,
          accept: String.t() | nil
        }

  def child_spec(spec) do
    key = {spec.kind, spec.digest}

    %{
      id: {__MODULE__, key},
      start:
        {GenServer, :start_link, [__MODULE__, spec, [name: {:via, Registry, {@registry, key}}]]},
      restart: :temporary
    }
  end

  @doc """
  Join the fetch of `spec`, starting it if nobody has. Returns
  `{:stored, meta}` when it's in the store, `{:fetching, info}` to tail,
  or `{:error, reason}` (`{:status, n}`, `:digest_mismatch`, `:busy`, ...).
  """
  def open(spec, tries \\ 3)

  def open(_spec, 0), do: {:error, :fetch_raced}

  def open(spec, tries) do
    case Store.lookup(spec.digest) do
      # Any stored object serves as a blob; only a manifest as a manifest.
      {:ok, %{kind: kind} = meta} when kind == spec.kind or spec.kind == :blob -> {:stored, meta}
      _ -> join(spec, tries)
    end
  end

  defp join(spec, tries) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, spec}) do
      {:ok, pid} -> join_pid(pid, spec, tries)
      {:error, {:already_started, pid}} -> join_pid(pid, spec, tries)
      {:error, :max_children} -> {:error, :busy}
    end
  end

  defp join_pid(pid, spec, tries) do
    case GenServer.call(pid, :join, @idle_ms) do
      {:fetching, info} -> {:fetching, Map.put(info, :ref, Process.monitor(info.pid))}
      other -> other
    end
  catch
    # It ended between the lookup and the join: it's stored now, or a
    # new fetch starts.
    :exit, _ -> open(spec, tries - 1)
  end

  @doc """
  Stop following a fetch: no more messages from it reach this process,
  which may serve more requests on the same connection.
  """
  def close(%{pid: pid, ref: ref}) do
    Process.demonitor(ref, [:flush])
    GenServer.cast(pid, {:leave, self()})
    flush(pid)
  end

  defp flush(pid) do
    receive do
      {:fetch_wake, ^pid} -> flush(pid)
      {:fetch_done, ^pid, _} -> flush(pid)
    after
      0 -> :ok
    end
  end

  @doc """
  Wait for a fetch to end, then leave it: `:ok` (it's in the store) or
  `{:error, reason}`.
  """
  def await(info) do
    wait_done(info)
  after
    close(info)
  end

  defp wait_done(%{done: done}) when done != nil, do: done

  defp wait_done(%{pid: pid, ref: ref}) do
    receive do
      {:fetch_done, ^pid, result} -> result
      {:DOWN, ^ref, :process, ^pid, _} -> {:error, :fetch_failed}
    after
      @idle_ms -> {:error, :timeout}
    end
  end

  @doc """
  Send the fetch's bytes to `conn` as they arrive, then leave it. `conn`
  must have had `send_chunked/2` called. Returns `{:ok, conn, bytes}`,
  or `{:error, conn, reason}` when the response can't be completed (the
  caller must abort it).
  """
  def stream(conn, info) do
    case open_file(info) do
      {:ok, io} ->
        try do
          tail(conn, io, info, 0)
        after
          File.close(io)
          close(info)
        end

      {:error, reason} ->
        close(info)
        {:error, conn, reason}
    end
  end

  # The temporary file is renamed into the store on success; a client
  # that only gets there afterwards reads it from the store.
  defp open_file(info) do
    case File.open(info.tmp, [:read, :raw, :binary]) do
      {:ok, io} ->
        {:ok, io}

      {:error, :enoent} ->
        case Store.lookup(info.digest) do
          {:ok, meta} -> File.open(meta.path, [:read, :raw, :binary])
          :error -> {:error, :gone}
        end

      error ->
        error
    end
  end

  defp tail(conn, io, info, offset) do
    written = :atomics.get(info.counter, 1)
    limit = if info.done == :ok, do: written, else: max(written - 1, 0)

    cond do
      offset < limit ->
        case :file.pread(io, offset, min(limit - offset, 256 * 1024)) do
          {:ok, data} -> send_part(conn, io, info, offset, data)
          :eof -> tail(conn, io, wait(info, written), offset)
          {:error, reason} -> {:error, conn, reason}
        end

      info.done == :ok ->
        {:ok, conn, offset}

      match?({:error, _}, info.done) ->
        {:error, conn, elem(info.done, 1)}

      true ->
        tail(conn, io, wait(info, written), offset)
    end
  end

  defp send_part(conn, io, info, offset, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> tail(conn, io, info, offset + byte_size(data))
      {:error, reason} -> {:error, conn, {:client, reason}}
    end
  end

  # Park until there's more than `seen`, or the fetch ends.
  defp wait(%{pid: pid, ref: ref} = info, seen) do
    GenServer.cast(pid, {:park, self(), seen})

    receive do
      {:fetch_wake, ^pid} -> info
      {:fetch_done, ^pid, result} -> %{info | done: result}
      {:DOWN, ^ref, :process, ^pid, _} -> %{info | done: info.done || {:error, :fetch_failed}}
    after
      @idle_ms -> %{info | done: {:error, :timeout}}
    end
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)
    tmp = Store.tmp_path()
    counter = :atomics.new(1, signed: false)
    parent = self()
    worker = spawn_link(fn -> download(parent, spec, tmp, counter) end)

    {:ok,
     %{
       spec: spec,
       tmp: tmp,
       counter: counter,
       worker: worker,
       waiting: [],
       subs: %{},
       parked: [],
       headers: nil,
       done: nil
     }}
  end

  @impl true
  def handle_call(:join, {pid, _} = from, state) do
    state = subscribe(state, pid)

    cond do
      match?({:error, _}, state.done) -> {:reply, state.done, state}
      state.headers != nil -> {:reply, {:fetching, info(state)}, state}
      true -> {:noreply, %{state | waiting: [from | state.waiting]}}
    end
  end

  defp subscribe(state, pid) do
    if Map.has_key?(state.subs, pid),
      do: state,
      else: %{state | subs: Map.put(state.subs, pid, Process.monitor(pid))}
  end

  defp info(state) do
    {size, content_type} = state.headers

    %{
      pid: self(),
      tmp: state.tmp,
      digest: state.spec.digest,
      size: size,
      content_type: content_type,
      counter: state.counter,
      done: state.done
    }
  end

  @impl true
  def handle_info({:headers, size, content_type}, state) do
    state = %{state | headers: {size, content_type}}
    for from <- state.waiting, do: GenServer.reply(from, {:fetching, info(state)})
    {:noreply, %{state | waiting: []}}
  end

  def handle_info(:progress, state) do
    for pid <- state.parked, do: send(pid, {:fetch_wake, self()})
    {:noreply, %{state | parked: []}}
  end

  def handle_info({:finished, source, result}, state),
    do: finish(verify(result, source, state), source, state)

  def handle_info({:EXIT, worker, reason}, %{worker: worker, done: nil} = state)
      when reason != :normal do
    Logger.error(
      "fetch of #{state.spec.digest} crashed: #{inspect(reason) |> String.slice(0, 300)}"
    )

    File.rm(state.tmp)
    finish({:error, :fetch_failed}, :upstream, state)
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _, :process, pid, _}, state),
    do:
      {:noreply,
       %{state | subs: Map.delete(state.subs, pid), parked: List.delete(state.parked, pid)}}

  def handle_info(:linger_over, state), do: {:stop, :normal, state}

  @impl true
  def handle_cast({:leave, pid}, state) do
    {ref, subs} = Map.pop(state.subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | subs: subs, parked: List.delete(state.parked, pid)}}
  end

  def handle_cast({:park, pid, seen}, state) do
    if :atomics.get(state.counter, 1) > seen or state.done != nil do
      send(pid, {:fetch_wake, self()})
      {:noreply, state}
    else
      {:noreply, %{state | parked: [pid | List.delete(state.parked, pid)]}}
    end
  end

  # Shut down before the download finished: it mustn't leave its file.
  @impl true
  def terminate(_reason, %{done: nil} = state), do: File.rm(state.tmp)
  def terminate(_reason, _state), do: :ok

  defp verify({:ok, hex, size, content_type}, source, %{spec: spec} = state) do
    if "sha256:" <> hex == spec.digest do
      meta = %{
        kind: spec.kind,
        media_type: media_type(spec.kind, state.tmp, content_type),
        host: spec.host.host,
        repo: spec.repo,
        size: size
      }

      with :ok <- Store.commit(state.tmp, spec.digest, meta), do: {:ok, size}
    else
      Stats.mismatch(spec.host.host)

      Logger.warning(
        "digest mismatch from the #{source} (#{spec.host.host}) for #{spec.repo}@#{spec.digest}"
      )

      if source == :parent, do: CrewCache.Parent.skip(spec.digest)
      File.rm(state.tmp)
      {:error, :digest_mismatch}
    end
  end

  defp verify({:error, _} = error, _source, state) do
    File.rm(state.tmp)
    error
  end

  # A manifest's own mediaType, when it has one, over the Content-Type it
  # came with: the bytes are verified, the header isn't.
  defp media_type(:manifest, path, content_type) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"mediaType" => type}} when is_binary(type) <- Jason.decode(json) do
      type
    else
      _ -> content_type
    end
  end

  defp media_type(:blob, _path, content_type), do: content_type

  defp finish({:ok, size}, _source, state) do
    state = %{state | headers: state.headers || {size, nil}, done: :ok}
    notify(state, :ok)
    {:stop, :normal, state}
  end

  # A mismatch from the upstream lingers, so requests get a 502 for a
  # while without asking again. Anything else, or anything from the
  # parent, ends the fetch: the next try starts afresh (or goes upstream).
  defp finish({:error, reason} = error, source, state) do
    state = %{state | done: error}
    notify(state, error)

    if reason == :digest_mismatch and source == :upstream do
      Process.send_after(self(), :linger_over, @failed_linger_ms)
      {:noreply, %{state | waiting: [], parked: []}}
    else
      {:stop, :normal, state}
    end
  end

  defp notify(state, result) do
    for from <- state.waiting, do: GenServer.reply(from, waiting_reply(state, result))
    for {pid, _} <- state.subs, do: send(pid, {:fetch_done, self(), result})
  end

  defp waiting_reply(state, :ok), do: {:fetching, info(state)}
  defp waiting_reply(_state, error), do: error

  # -- the download --------------------------------------------------------------

  defp download(parent, spec, tmp, counter) do
    {:ok, io} = File.open(tmp, [:write, :raw, :binary])
    limit = if spec.kind == :manifest, do: @manifest_max, else: blob_max()

    acc = %{
      parent: parent,
      io: io,
      counter: counter,
      hash: :crypto.hash_init(:sha256),
      written: 0,
      limit: limit,
      media_type: nil,
      error: nil,
      started: false
    }

    headers = if spec.accept, do: [{"accept", spec.accept}], else: []
    path = if spec.kind == :manifest, do: "manifests/", else: "blobs/"

    {source, result} =
      case CrewCache.Parent.fetch(spec, headers, {&sink/2, acc}) do
        fallback when fallback in [:skip, :fallback] ->
          {:upstream,
           Upstream.request(spec.host, spec.repo, "GET", path <> spec.digest,
             headers: headers,
             sink: {&sink/2, acc}
           )}

        from_parent ->
          {:parent, from_parent}
      end

    # Durable before the rename makes it visible (CrewCache.Store.commit/3).
    :file.sync(io)
    File.close(io)
    send(parent, {:finished, source, outcome(result)})
  end

  defp outcome({:ok, %{status: status, sink: %{error: nil} = acc}}) when status in 200..299,
    do:
      {:ok, Base.encode16(:crypto.hash_final(acc.hash), case: :lower), acc.written,
       acc.media_type}

  defp outcome({:ok, %{sink: %{error: error}}}) when error != nil, do: {:error, error}
  defp outcome({:ok, %{status: status}}), do: {:error, {:status, status}}
  defp outcome({:error, reason, _sink}), do: {:error, reason}
  defp outcome({:error, reason}), do: {:error, reason}

  defp sink({:headers, _status, headers}, acc) do
    size =
      case Integer.parse(Upstream.header(headers, "content-length") || "") do
        {n, ""} when n >= 0 -> n
        _ -> nil
      end

    cond do
      size && size > acc.limit ->
        {:halt, %{acc | error: :too_large}}

      # The reservation lasts as long as this process (the store watches it).
      size && Store.reserve(size) != :ok ->
        {:halt, %{acc | error: :too_large}}

      true ->
        content_type = Upstream.header(headers, "content-type")
        send(acc.parent, {:headers, size, content_type})
        {:cont, %{acc | media_type: content_type, started: true}}
    end
  end

  defp sink({:data, data}, acc) do
    written = acc.written + byte_size(data)

    if written > acc.limit do
      {:halt, %{acc | error: :too_large}}
    else
      case :file.write(acc.io, data) do
        :ok ->
          :atomics.put(acc.counter, 1, written)
          send(acc.parent, :progress)
          {:cont, %{acc | hash: :crypto.hash_update(acc.hash, data), written: written}}

        {:error, reason} ->
          {:halt, %{acc | error: {:write, reason}}}
      end
    end
  end

  # One object may take at most half the store.
  defp blob_max, do: div(CrewCache.Config.get().max_bytes, 2)
end
