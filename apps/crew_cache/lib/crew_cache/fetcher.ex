defmodule CrewCache.Fetcher do
  @moduledoc """
  One upstream fetch of one digest, shared by everyone who asks for it
  while it runs (§15.3: identical concurrent fetches are coalesced).

  The download runs in its own linked process, writing a temporary file
  in the store and hashing as it goes; it carries on if the clients go.
  Clients `open/1` the fetch and tail the file (`stream/3`), so the
  first byte reaches every client as soon as it's on disk. The last byte
  is held back until the digest is verified: a mismatch cuts every
  response short, so no client ever gets a complete wrong blob.

  When the SHA-256 matches, the file is committed to the store and the
  fetch ends. When it doesn't, nothing is stored, the mismatch is
  counted, and the failed fetch stays registered for #{30} seconds so
  requests for that digest get a 502 without asking the upstream again.

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
    %{
      id: {__MODULE__, spec.digest},
      start: {GenServer, :start_link, [__MODULE__, spec, [name: via(spec.digest)]]},
      restart: :temporary
    }
  end

  defp via(digest), do: {:via, Registry, {@registry, digest}}

  @doc """
  Join the fetch of `spec.digest`, starting it if nobody has. Returns
  `{:stored, meta}` when it's in the store, `{:fetching, info}` to tail,
  or `{:error, reason}` (`{:status, n}`, `:digest_mismatch`, ...).
  """
  def open(spec, tries \\ 3)

  def open(_spec, 0), do: {:error, :fetch_raced}

  def open(spec, tries) do
    case Store.lookup(spec.digest) do
      {:ok, meta} -> {:stored, meta}
      :error -> join(spec, tries)
    end
  end

  defp join(spec, tries) do
    pid =
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, spec}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

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
      {:fetch_progress, ^pid, _} -> flush(pid)
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

  defp wait_done(%{pid: pid, ref: ref} = info) do
    receive do
      {:fetch_progress, ^pid, _} -> wait_done(info)
      {:fetch_done, ^pid, result} -> result
      {:DOWN, ^ref, :process, ^pid, _} -> {:error, :fetch_failed}
    after
      @idle_ms -> {:error, :timeout}
    end
  end

  @doc """
  Send the fetch's bytes to `conn` as they arrive, from `offset`, then
  leave it. `conn` must have had `send_chunked/2` called. Returns
  `{:ok, conn, bytes}`, or `{:error, conn, reason}` when the response
  can't be completed (the caller must abort it).
  """
  def stream(conn, info, offset \\ 0) do
    case open_file(info) do
      {:ok, io} ->
        try do
          tail(conn, io, info, offset, 0)
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

  defp tail(conn, io, info, offset, sent) do
    limit = if info.done == :ok, do: info.written, else: max(info.written - 1, 0)

    cond do
      offset < limit ->
        case :file.pread(io, offset, min(limit - offset, 256 * 1024)) do
          {:ok, data} -> send_part(conn, io, info, offset, sent, data)
          :eof -> tail(conn, io, wait(info), offset, sent)
          {:error, reason} -> {:error, conn, reason}
        end

      info.done == :ok ->
        {:ok, conn, sent}

      match?({:error, _}, info.done) ->
        {:error, conn, elem(info.done, 1)}

      true ->
        tail(conn, io, wait(info), offset, sent)
    end
  end

  defp send_part(conn, io, info, offset, sent, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> tail(conn, io, info, offset + byte_size(data), sent + byte_size(data))
      {:error, reason} -> {:error, conn, {:client, reason}}
    end
  end

  defp wait(%{pid: pid, ref: ref} = info) do
    receive do
      {:fetch_progress, ^pid, written} -> %{info | written: max(written, info.written)}
      {:fetch_done, ^pid, result} when result == :ok -> %{info | done: :ok}
      {:fetch_done, ^pid, error} -> %{info | done: error}
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
    parent = self()
    worker = spawn_link(fn -> download(parent, spec, tmp) end)

    {:ok,
     %{
       spec: spec,
       tmp: tmp,
       worker: worker,
       waiting: [],
       subs: %{},
       headers: nil,
       written: 0,
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
      written: state.written,
      done: state.done
    }
  end

  @impl true
  def handle_info({:headers, size, content_type}, state) do
    state = %{state | headers: {size, content_type}}
    for from <- state.waiting, do: GenServer.reply(from, {:fetching, info(state)})
    {:noreply, %{state | waiting: []}}
  end

  def handle_info({:progress, written}, state) do
    for {pid, _} <- state.subs, do: send(pid, {:fetch_progress, self(), written})
    {:noreply, %{state | written: written}}
  end

  def handle_info({:finished, source, result}, state),
    do: finish(verify(result, source, state), source, state)

  def handle_info({:EXIT, worker, reason}, %{worker: worker, done: nil} = state)
      when reason != :normal do
    Logger.error(
      "fetch of #{state.spec.digest} crashed: #{inspect(reason) |> String.slice(0, 300)}"
    )

    finish({:error, :fetch_failed}, :upstream, state)
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, _, :process, pid, _}, state),
    do: {:noreply, %{state | subs: Map.delete(state.subs, pid)}}

  def handle_info(:linger_over, state), do: {:stop, :normal, state}

  @impl true
  def handle_cast({:leave, pid}, state) do
    {ref, subs} = Map.pop(state.subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | subs: subs}}
  end

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
    state = %{state | written: size, headers: state.headers || {size, nil}}
    notify(state, :ok)
    {:stop, :normal, %{state | done: :ok}}
  end

  # A failure from the upstream lingers, so requests get a 502 for a
  # while without asking again. One from the parent doesn't: the next
  # try goes upstream.
  defp finish({:error, _} = error, source, state) do
    notify(state, error)

    if source == :parent,
      do: send(self(), :linger_over),
      else: Process.send_after(self(), :linger_over, @failed_linger_ms)

    {:noreply, %{state | done: error, waiting: []}}
  end

  defp notify(state, result) do
    for from <- state.waiting, do: GenServer.reply(from, waiting_reply(state, from, result))
    for {pid, _} <- state.subs, do: send(pid, {:fetch_done, self(), result})
  end

  defp waiting_reply(state, _from, :ok), do: {:fetching, %{info(state) | done: :ok}}
  defp waiting_reply(_state, _from, error), do: error

  # -- the download --------------------------------------------------------------

  defp download(parent, spec, tmp) do
    {:ok, io} = File.open(tmp, [:write, :raw, :binary])
    limit = if spec.kind == :manifest, do: @manifest_max, else: blob_max()

    acc = %{
      parent: parent,
      io: io,
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
      case Upstream.header(headers, "content-length") do
        nil -> nil
        text -> String.to_integer(text)
      end

    if size && size > acc.limit do
      {:halt, %{acc | error: :too_large}}
    else
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
      :ok = IO.binwrite(acc.io, data)
      send(acc.parent, {:progress, written})
      {:cont, %{acc | hash: :crypto.hash_update(acc.hash, data), written: written}}
    end
  end

  # One object may take at most half the store.
  defp blob_max, do: div(CrewCache.Config.get().max_bytes, 2)
end
