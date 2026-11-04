defmodule CrewCache.FakeRegistry do
  @moduledoc """
  An upstream registry for tests, in-process, over TLS: `registry.test`
  serves the distribution API and an anonymous token endpoint, and
  redirects blobs to `storage.test`, a second listener, as Docker Hub
  and GHCR do. Both resolve to 127.0.0.1 through the cache's test
  resolver.

  - Manifests by tag and digest, with `Docker-Content-Digest`, and an
    `Accept` check (a manifest whose type isn't accepted is a 404).
  - The bearer challenge: requests without a token for the repository
    get a 401 pointing at `challenge_realm` (which the cache must ignore
    in favour of the compiled realm).
  - Private repositories deny anonymous tokens.
  - `corrupt/1` serves wrong bytes for a digest; `slow/2` drips a blob.
  - Every request is recorded with its `Authorization` header.
  """

  use Agent

  @manifest_type "application/vnd.oci.image.manifest.v1+json"
  @config_type "application/vnd.oci.image.config.v1+json"
  @layer_type "application/vnd.oci.image.layer.v1.tar+gzip"

  def manifest_type, do: @manifest_type

  @doc "Start both listeners. Returns their ports and the CA to trust."
  def start do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
          intermediates: [],
          peer: [
            key: {:namedCurve, :secp256r1},
            digest: :sha256,
            extensions: [
              {:Extension, {2, 5, 29, 17}, false,
               [{:dNSName, ~c"registry.test"}, {:dNSName, ~c"storage.test"}]}
            ]
          ]
        },
        client_chain: %{root: [], intermediates: [], peer: []}
      })

    tls = Keyword.take(server, [:cert, :key, :cacerts])

    {:ok, _} =
      Agent.start_link(
        fn ->
          %{
            repos: %{},
            manifests: %{},
            blobs: %{},
            corrupt: MapSet.new(),
            slow: %{},
            redirect_host: %{},
            requests: [],
            tokens: %{},
            token_ttl: 300,
            challenge_realm: nil,
            storage_port: nil
          }
        end,
        name: __MODULE__
      )

    registry = listen({__MODULE__.Plug, :registry}, tls)
    storage = listen({__MODULE__.Plug, :storage}, tls)
    update(&%{&1 | storage_port: storage})

    %{registry_port: registry, storage_port: storage, cacerts: Keyword.fetch!(client, :cacerts)}
  end

  defp listen(plug, tls) do
    {:ok, pid} =
      Bandit.start_link(
        plug: plug,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [transport_options: tls]
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp update(fun), do: Agent.update(__MODULE__, fun)
  def state, do: Agent.get(__MODULE__, & &1)

  def digest(body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  @doc """
  Add an image: a config blob, the given layers and a manifest, tagged.
  Returns the digests and the manifest's bytes.
  """
  def put_image(repo, tag, layers, opts \\ []) do
    config = Jason.encode!(%{"architecture" => "arm64", "os" => "linux", "repo" => repo})

    manifest =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => @manifest_type,
        "config" => descriptor(@config_type, config),
        "layers" => Enum.map(layers, &descriptor(@layer_type, &1))
      })

    blobs = Map.new([config | layers], &{digest(&1), &1})
    manifest_digest = digest(manifest)

    update(fn s ->
      repo_state = Map.get(s.repos, repo, %{tags: %{}, public: true})

      %{
        s
        | repos:
            Map.put(s.repos, repo, %{
              repo_state
              | tags: Map.put(repo_state.tags, tag, manifest_digest),
                public: Keyword.get(opts, :public, true)
            }),
          manifests: Map.put(s.manifests, manifest_digest, {@manifest_type, manifest}),
          blobs: Map.merge(s.blobs, blobs)
      }
    end)

    %{
      manifest: manifest_digest,
      manifest_body: manifest,
      config: digest(config),
      layers: Enum.map(layers, &digest/1)
    }
  end

  defp descriptor(type, body),
    do: %{"mediaType" => type, "digest" => digest(body), "size" => byte_size(body)}

  @doc "Point a tag somewhere else, as a push would."
  def retag(repo, tag, manifest_digest) do
    update(fn s -> put_in(s.repos[repo].tags[tag], manifest_digest) end)
  end

  def corrupt(digest), do: update(&%{&1 | corrupt: MapSet.put(&1.corrupt, digest)})
  def slow(digest, chunk_ms), do: update(&%{&1 | slow: Map.put(&1.slow, digest, chunk_ms)})

  @doc "Redirect a blob to another host name (e.g. one resolving into blocked4)."
  def redirect_host(digest, host),
    do: update(&%{&1 | redirect_host: Map.put(&1.redirect_host, digest, host)})

  def challenge_realm(url), do: update(&%{&1 | challenge_realm: url})
  def token_ttl(seconds), do: update(&%{&1 | token_ttl: seconds})

  def requests, do: state().requests |> Enum.reverse()
  def clear_requests, do: update(&%{&1 | requests: []})

  def count(server, method, path_part) do
    Enum.count(requests(), fn r ->
      r.server == server and r.method == method and String.contains?(r.path, path_part)
    end)
  end

  @doc "Like `count/3`, for requests that carried a token (not a first, challenged try)."
  def count_authorized(server, method, path_part) do
    Enum.count(requests(), fn r ->
      r.server == server and r.method == method and String.contains?(r.path, path_part) and
        r.authorization != nil
    end)
  end

  @doc false
  def record(entry), do: update(&%{&1 | requests: [entry | &1.requests]})

  @doc false
  def issue_token(repo) do
    Agent.get_and_update(__MODULE__, fn s ->
      token = "anon-#{map_size(s.tokens) + 1}-#{System.unique_integer([:positive])}"
      {{token, s.token_ttl}, %{s | tokens: Map.put(s.tokens, token, repo)}}
    end)
  end

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    alias CrewCache.FakeRegistry, as: Fake

    def init(which), do: which

    def call(conn, which) do
      auth = get_req_header(conn, "authorization") |> List.first()

      Fake.record(%{
        server: which,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        authorization: auth
      })

      route(conn, which, conn.path_info, auth)
    end

    defp route(conn, :registry, ["token"], _auth) do
      conn = fetch_query_params(conn)
      "repository:" <> rest = conn.query_params["scope"] || "repository:none:pull"
      [repo | _] = String.split(rest, ":")
      {token, ttl} = Fake.issue_token(repo)
      json(conn, 200, %{"token" => token, "expires_in" => ttl})
    end

    defp route(conn, :registry, ["v2" | rest], auth) when rest != [] do
      {repo_parts, [kind, ref]} = Enum.split(rest, -2)
      repo = Enum.join(repo_parts, "/")
      state = Fake.state()

      cond do
        not Map.has_key?(state.repos, repo) ->
          error(conn, 404, "NAME_UNKNOWN")

        not authorized?(state, repo, auth) ->
          challenge(conn, state, repo)

        kind == "manifests" ->
          manifest(conn, state, repo, ref)

        kind == "blobs" ->
          blob_redirect(conn, state, ref)
      end
    end

    defp route(conn, :storage, ["blobs", digest], _auth) do
      state = Fake.state()

      case Map.fetch(state.blobs, digest) do
        {:ok, body} ->
          body = if MapSet.member?(state.corrupt, digest), do: flip(body), else: body

          case Map.get(state.slow, digest) do
            nil ->
              conn
              |> put_resp_content_type("application/octet-stream", nil)
              |> send_resp(200, body)

            ms ->
              drip(conn, body, ms)
          end

        :error ->
          error(conn, 404, "BLOB_UNKNOWN")
      end
    end

    defp route(conn, _, _, _), do: error(conn, 404, "UNSUPPORTED")

    defp authorized?(state, repo, "Bearer " <> token) do
      state.repos[repo].public and Map.get(state.tokens, token) == repo
    end

    defp authorized?(_, _, _), do: false

    defp challenge(conn, state, repo) do
      realm = state.challenge_realm || "https://registry.test/token"

      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer realm="#{realm}",service="fake.test",scope="repository:#{repo}:pull")
      )
      |> error(401, "UNAUTHORIZED")
    end

    defp manifest(conn, state, repo, ref) do
      digest = if String.starts_with?(ref, "sha256:"), do: ref, else: state.repos[repo].tags[ref]

      with digest when is_binary(digest) <- digest,
           {:ok, {type, body}} <- Map.fetch(state.manifests, digest),
           true <- accepts?(conn, type) do
        body = if MapSet.member?(state.corrupt, digest), do: flip(body), else: body

        conn =
          conn
          |> put_resp_header("content-type", type)
          |> put_resp_header("docker-content-digest", digest)

        if conn.method == "HEAD" do
          conn |> put_resp_header("content-length", "#{byte_size(body)}") |> send_resp(200, "")
        else
          send_resp(conn, 200, body)
        end
      else
        _ -> error(conn, 404, "MANIFEST_UNKNOWN")
      end
    end

    defp accepts?(conn, type) do
      case get_req_header(conn, "accept") do
        [] -> true
        values -> values |> Enum.join(",") |> String.contains?(type)
      end
    end

    defp blob_redirect(conn, state, digest) do
      if Map.has_key?(state.blobs, digest) do
        host = Map.get(state.redirect_host, digest, "storage.test")

        conn
        |> put_resp_header(
          "location",
          "https://#{host}:#{state.storage_port}/blobs/#{digest}?sig=x"
        )
        |> send_resp(307, "")
      else
        error(conn, 404, "BLOB_UNKNOWN")
      end
    end

    defp drip(conn, body, ms) do
      conn =
        conn
        |> put_resp_header("content-length", "#{byte_size(body)}")
        |> send_chunked(200)

      body
      |> chunks(64 * 1024)
      |> Enum.reduce_while(conn, fn part, conn ->
        Process.sleep(ms)

        case chunk(conn, part) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end

    defp chunks(<<>>, _), do: []
    defp chunks(bin, n) when byte_size(bin) <= n, do: [bin]

    defp chunks(bin, n),
      do: [binary_part(bin, 0, n) | chunks(binary_part(bin, n, byte_size(bin) - n), n)]

    defp flip(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>

    defp json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end

    defp error(conn, status, code), do: json(conn, status, %{"errors" => [%{"code" => code}]})
  end
end
