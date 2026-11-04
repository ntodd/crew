defmodule CrewCache.Registry do
  @moduledoc """
  The registry mirror (§15.3), Design A: dockerd's containerd store and
  BuildKit send `GET`/`HEAD /v2/<prefix>/<repo>/manifests/<ref>` and
  `/blobs/<digest>` here (with `?ns=<host>`, ignored), where `<prefix>`
  is a compiled host's path prefix (`docker.io` for Docker Hub).

  | Request | Allowlisted repo of an enabled host | Otherwise |
  |---|---|---|
  | `GET/HEAD /v2/` | 200, `registry/2.0`: there's no single upstream to pass it to | |
  | manifest by digest | the store, or fetched anonymously, verified, stored | 404 |
  | manifest by tag | an upstream HEAD for the digest (60 s micro-cache keyed on the normalised `Accept`), then by digest; `Content-Type` and `Docker-Content-Digest` as the upstream sent them | 404 |
  | blob | the store (with `Range`), or fetched anonymously and streamed (`CrewCache.Fetcher`); HEAD asks the upstream and stores nothing | 404 |
  | anything else under `/v2/<prefix>/` | 404 | 404 |
  | any other method | 405 | 405 |

  **Why 404, not pass-through:** under Design A the mirror only ever gets
  anonymous requests (dockerd keeps credentials for the real registry),
  and containerd tries the upstream itself on any error of 400 or more.
  Answering 404 keeps the cache from being an open anonymous proxy to
  every repository on seven registries, and leaves private repositories
  and anything the cache can't serve to the client's own credentials.
  An anonymous fetch that fails (a private repository under an
  allowlisted glob) is also a 404; failures of the upstream itself are
  502. Neither carries a `WWW-Authenticate`, so containerd doesn't try
  to log in to the mirror.

  The client's `Authorization` is never read, sent on or logged.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias CrewCache.{Allowlist, Config, Fetcher, Settings, Stats, Store, Upstream}
  alias CrewCache.Upstream.Memo

  defmodule Aborted do
    @moduledoc "Ends a response that can't be completed. Bandit closes the connection; 499 isn't logged."
    defexception message: "response aborted", plug_status: 499
  end

  @read ~w(GET HEAD)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("docker-distribution-api-version", "registry/2.0")
    |> route(conn.method, conn.path_info)
  end

  defp route(conn, method, ["healthz"]) when method in @read, do: send_resp(conn, 200, "ok")

  # The API version check. A client pinging its mirror base
  # (/v2/<prefix>/) gets the same.
  defp route(conn, method, ["v2" | rest]) when method in @read and length(rest) <= 1,
    do: json(conn, 200, %{})

  defp route(conn, method, ["v2" | _]) when method not in @read,
    do: error(conn, 405, "UNSUPPORTED", "the cache is read-only")

  defp route(conn, _method, ["v2", prefix | rest]) do
    with {:ok, host} <- host(prefix),
         {:ok, repo, kind, ref} <- parse(rest),
         :ok <- allowed(host, repo) do
      case kind do
        "manifests" -> manifest(conn, host, repo, ref)
        "blobs" -> blob(conn, host, repo, ref)
      end
    else
      {:error, code, message} -> error(conn, 404, code, message)
    end
  end

  defp route(conn, _method, _path), do: error(conn, 404, "NOT_FOUND", "not a registry path")

  defp host(prefix) do
    case Allowlist.host_for_prefix(prefix) do
      nil ->
        {:error, "NAME_UNKNOWN", "not a registry the cache knows"}

      host ->
        if MapSet.member?(Settings.current().enabled, host.host),
          do: {:ok, host},
          else: {:error, "NAME_UNKNOWN", "not a registry the cache serves"}
    end
  end

  defp parse(rest) do
    with {[_ | _] = parts, [kind, ref]} when kind in ~w(manifests blobs) <- Enum.split(rest, -2),
         repo = Enum.join(parts, "/"),
         true <- Allowlist.valid_repo?(repo) do
      {:ok, repo, kind, ref}
    else
      _ -> {:error, "NAME_UNKNOWN", "not a manifest or blob path"}
    end
  end

  defp allowed(host, repo) do
    if Allowlist.allowed?(Settings.current().allow, host.host, repo),
      do: :ok,
      else: {:error, "NAME_UNKNOWN", "not cached"}
  end

  # -- manifests ------------------------------------------------------------------

  defp manifest(conn, host, repo, ref) do
    accept = accept(conn)

    cond do
      match?({:ok, _}, Allowlist.digest(ref)) ->
        serve_manifest(conn, host, repo, ref, accept, nil)

      Allowlist.valid_tag?(ref) ->
        case resolve_tag(host, repo, ref, accept) do
          {:ok, %{digest: digest, content_type: type}} ->
            serve_manifest(conn, host, repo, digest, accept, type)

          {:error, status} ->
            error(conn, status, "MANIFEST_UNKNOWN", "the upstream didn't resolve the tag")
        end

      true ->
        error(conn, 404, "MANIFEST_UNKNOWN", "not a tag or digest")
    end
  end

  defp accept(conn) do
    case get_req_header(conn, "accept") do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  # Always the real upstream, never the parent (§15.5).
  defp resolve_tag(host, repo, tag, accept) do
    key = {host.host, repo, tag, Upstream.normalise_accept(accept)}

    with :error <- Memo.tag(key) do
      headers = if accept, do: [{"accept", accept}], else: []

      case Upstream.request(host, repo, "HEAD", "manifests/" <> tag, headers: headers) do
        {:ok, %{status: 200, headers: headers}} ->
          digest = Upstream.header(headers, "docker-content-digest") || ""

          if match?({:ok, _}, Allowlist.digest(digest)) do
            value = %{digest: digest, content_type: Upstream.header(headers, "content-type")}
            Memo.put_tag(key, value, Config.get().tag_ttl_ms)
            {:ok, value}
          else
            {:error, 404}
          end

        {:ok, %{status: status}} ->
          {:error, if(status >= 500, do: 502, else: 404)}

        {:error, reason} ->
          Logger.warning("couldn't resolve #{host.host}/#{repo}:#{tag}: #{describe(reason)}")
          {:error, 502}
      end
    end
  end

  defp serve_manifest(conn, host, repo, digest, accept, type) do
    case Store.lookup(digest) do
      {:ok, %{kind: :manifest} = meta} ->
        Stats.hit(host.host, repo)
        Store.touch(digest)
        send_manifest(conn, host, repo, meta, type)

      _ ->
        Stats.miss(host.host, repo)
        spec = %{host: host, repo: repo, digest: digest, kind: :manifest, accept: accept}

        with {:fetching, info} <- Fetcher.open(spec),
             :ok <- Fetcher.await(info),
             {:ok, %{kind: :manifest} = meta} <- Store.lookup(digest) do
          send_manifest(conn, host, repo, meta, type)
        else
          {:stored, %{kind: :manifest} = meta} -> send_manifest(conn, host, repo, meta, type)
          {:error, reason} -> fetch_error(conn, host, repo, digest, reason)
          _ -> error(conn, 404, "MANIFEST_UNKNOWN", "not a manifest")
        end
    end
  end

  defp send_manifest(conn, host, repo, meta, type) do
    conn =
      conn
      |> put_resp_header("content-type", type || meta.media_type || "application/octet-stream")
      |> put_resp_header("docker-content-digest", meta.digest)

    if conn.method == "HEAD" do
      conn |> put_resp_header("content-length", "#{meta.size}") |> send_resp(200, "")
    else
      Stats.served(host.host, repo, meta.size)
      send_file(conn, 200, meta.path)
    end
  end

  # -- blobs ------------------------------------------------------------------------

  defp blob(conn, host, repo, digest) do
    case Allowlist.digest(digest) do
      {:ok, _} -> stored_or_fetched_blob(conn, host, repo, digest)
      :error -> error(conn, 404, "BLOB_UNKNOWN", "not a sha256 digest")
    end
  end

  defp stored_or_fetched_blob(conn, host, repo, digest) do
    case Store.lookup(digest) do
      {:ok, meta} ->
        Stats.hit(host.host, repo)
        Store.touch(digest)
        send_stored_blob(conn, host, repo, meta)

      :error when conn.method == "HEAD" ->
        head_blob(conn, host, repo, digest)

      :error ->
        Stats.miss(host.host, repo)
        fetch_blob(conn, host, repo, digest)
    end
  end

  defp send_stored_blob(conn, host, repo, meta) do
    conn =
      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header("docker-content-digest", meta.digest)
      |> put_resp_header("accept-ranges", "bytes")

    case range(conn, meta.size) do
      _ when conn.method == "HEAD" ->
        conn |> put_resp_header("content-length", "#{meta.size}") |> send_resp(200, "")

      {:ok, from, to} ->
        Stats.served(host.host, repo, to - from + 1)

        conn
        |> put_resp_header("content-range", "bytes #{from}-#{to}/#{meta.size}")
        |> send_file(206, meta.path, from, to - from + 1)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{meta.size}") |> send_resp(416, "")

      :none ->
        Stats.served(host.host, repo, meta.size)
        send_file(conn, 200, meta.path)
    end
  end

  # One `bytes=` range; anything else is served whole.
  defp range(conn, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] -> parse_range(spec, size)
      _ -> :none
    end
  end

  defp parse_range(spec, size) do
    case Regex.run(~r/\A(\d*)-(\d*)\z/, String.trim(spec)) do
      [_, "", ""] -> :none
      [_, "", n] -> suffix_range(String.to_integer(n), size)
      [_, from, ""] -> bounded(String.to_integer(from), size - 1, size)
      [_, from, to] -> bounded(String.to_integer(from), String.to_integer(to), size)
      nil -> :none
    end
  end

  defp suffix_range(0, _size), do: :unsatisfiable
  defp suffix_range(n, size), do: bounded(max(size - n, 0), size - 1, size)

  defp bounded(from, _to, size) when from >= size, do: :unsatisfiable
  defp bounded(from, to, _size) when to < from, do: :none
  defp bounded(from, to, size), do: {:ok, from, min(to, size - 1)}

  defp head_blob(conn, host, repo, digest) do
    case Upstream.request(host, repo, "HEAD", "blobs/" <> digest) do
      {:ok, %{status: 200, headers: headers}} ->
        conn
        |> put_resp_header("content-type", "application/octet-stream")
        |> put_resp_header("docker-content-digest", digest)
        |> put_resp_header("content-length", Upstream.header(headers, "content-length") || "0")
        |> send_resp(200, "")

      _ ->
        error(conn, 404, "BLOB_UNKNOWN", "not available")
    end
  end

  defp fetch_blob(conn, host, repo, digest) do
    spec = %{host: host, repo: repo, digest: digest, kind: :blob, accept: nil}

    case Fetcher.open(spec) do
      {:stored, meta} ->
        send_stored_blob(conn, host, repo, meta)

      {:fetching, info} ->
        conn =
          conn
          |> put_resp_header("content-type", "application/octet-stream")
          |> put_resp_header("docker-content-digest", digest)
          |> then(
            &if(info.size, do: put_resp_header(&1, "content-length", "#{info.size}"), else: &1)
          )
          |> send_chunked(200)

        case Fetcher.stream(conn, info) do
          {:ok, conn, bytes} ->
            Stats.served(host.host, repo, bytes)
            conn

          {:error, conn, {:client, _}} ->
            conn

          {:error, _conn, reason} ->
            Logger.warning("cut short #{host.host}/#{repo}@#{digest}: #{describe(reason)}")
            raise Aborted
        end

      {:error, reason} ->
        fetch_error(conn, host, repo, digest, reason)
    end
  end

  defp fetch_error(conn, host, repo, digest, reason) do
    {status, code} = status_for(reason)

    if status == 502 or reason not in [{:status, 401}, {:status, 403}, {:status, 404}] do
      Logger.info("couldn't fetch #{host.host}/#{repo}@#{digest}: #{describe(reason)}")
    end

    error(conn, status, code, "the cache couldn't fetch it")
  end

  # 404s send containerd to the upstream; so do 502 and 503, which mean
  # the cache or the upstream failed rather than "not here".
  defp status_for(:digest_mismatch), do: {502, "DIGEST_INVALID"}
  defp status_for(:busy), do: {503, "UNAVAILABLE"}
  defp status_for({:status, status}) when status in 400..499, do: {404, "NAME_UNKNOWN"}
  defp status_for(:too_large), do: {404, "BLOB_UNKNOWN"}
  defp status_for(:no_space), do: {404, "BLOB_UNKNOWN"}
  defp status_for(:eacces), do: {404, "NAME_UNKNOWN"}
  defp status_for(%{reason: :eacces}), do: {404, "NAME_UNKNOWN"}
  defp status_for(_), do: {502, "UNAVAILABLE"}

  defp describe({:status, status}), do: "upstream status #{status}"
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other)

  # -- responses ----------------------------------------------------------------------

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error(conn, status, code, message),
    do: json(conn, status, %{"errors" => [%{"code" => code, "message" => message}]})
end
