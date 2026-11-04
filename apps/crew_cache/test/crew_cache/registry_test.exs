defmodule CrewCache.RegistryTest do
  use ExUnit.Case, async: false

  import CrewCache.CacheCase
  import ExUnit.CaptureLog

  alias CrewCache.{CA, FakeRegistry, Stats, Store}
  alias CrewCache.CA.Certs

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = tags do
    %{ctx: start_cache(dir, Map.get(tags, :cache, []))}
  end

  defp layers, do: [:crypto.strong_rand_bytes(3000), :crypto.strong_rand_bytes(70_000)]

  describe "the API root" do
    test "GET /v2/ answers as a registry does an anonymous client", %{ctx: ctx} do
      resp = req(ctx, :get, "/v2/")
      assert resp.status == 200
      assert resp.headers["docker-distribution-api-version"] == ["registry/2.0"]
      assert FakeRegistry.requests() == []
    end

    test "plain HTTP answers /healthz and nothing else", %{ctx: ctx} do
      http = "http://127.0.0.1:#{ctx.ports.http}"
      assert %{status: 200} = Req.get!(http <> "/healthz", retry: false)
      assert %{status: 404} = Req.get!(http <> "/v2/", retry: false)
    end
  end

  describe "a pull through the mirror (Design A)" do
    test "HEAD by tag, the manifest by digest, then blobs; the second pull is all hits",
         %{ctx: ctx} do
      image = FakeRegistry.put_image("library/alpine", "3.22", layers())

      first = pull(ctx, "docker.io", "library/alpine", "3.22")
      assert first.head.headers["docker-content-digest"] == [image.manifest]
      assert first.head.headers["content-type"] == [FakeRegistry.manifest_type()]
      assert first.manifest.body == image.manifest_body
      assert first.manifest.headers["content-type"] == [FakeRegistry.manifest_type()]

      for {digest, body} <- first.blobs do
        assert FakeRegistry.digest(body) == digest
      end

      # The HEAD by tag fetched the manifest, so the GET by digest was a hit.
      assert %{hits: 1, misses: 4} = Stats.snapshot().hosts["registry-1.docker.io"]

      FakeRegistry.clear_requests()
      second = pull(ctx, "docker.io", "library/alpine", "3.22")
      assert second.blobs == first.blobs
      assert FakeRegistry.requests() == []
      assert %{hits: 6, misses: 4} = Stats.snapshot().hosts["registry-1.docker.io"]

      assert [%{host: "registry-1.docker.io", repo: "library/alpine", hits: 6}] =
               Stats.snapshot().top
    end

    # Go clients (containerd) negotiate HTTP/2 through ALPN.
    test "the same pull over HTTP/2", %{ctx: ctx} do
      big = :crypto.strong_rand_bytes(300_000)
      image = FakeRegistry.put_image("library/debian", "13", [big])
      FakeRegistry.slow(FakeRegistry.digest(big), 5)
      h2 = Map.put(ctx, :protocols, [:http2])

      first = pull(h2, "docker.io", "library/debian", "13")
      assert first.head.headers["docker-content-digest"] == [image.manifest]
      assert {FakeRegistry.digest(big), big} in first.blobs
      assert pull(h2, "docker.io", "library/debian", "13").blobs == first.blobs
    end

    @tag cache: [tag_ttl_ms: 0]
    test "a tag is resolved upstream every time, past the micro-cache", %{ctx: ctx} do
      first = FakeRegistry.put_image("actions/runner", "latest", layers())
      pull(ctx, "ghcr.io", "actions/runner", "latest")

      second = FakeRegistry.put_image("actions/runner", "latest", layers())
      FakeRegistry.clear_requests()
      again = pull(ctx, "ghcr.io", "actions/runner", "latest")

      refute first.manifest == second.manifest
      assert again.head.headers["docker-content-digest"] == [second.manifest]
      assert FakeRegistry.count(:registry, "HEAD", "/manifests/latest") == 1
    end

    test "the micro-cache is keyed by Accept", %{ctx: ctx} do
      FakeRegistry.put_image("actions/runner", "v1", layers())
      accept = [{"accept", FakeRegistry.manifest_type()}]
      path = "/v2/ghcr.io/actions/runner/manifests/v1"

      assert %{status: 200} = req(ctx, :head, path, headers: accept)
      assert %{status: 200} = req(ctx, :head, path, headers: accept)
      # The same types in another order and with parameters are the same key.
      assert %{status: 200} =
               req(ctx, :head, path,
                 headers: [{"accept", "application/vnd.oci.image.manifest.v1+json;q=0.9"}]
               )

      assert FakeRegistry.count_authorized(:registry, "HEAD", "/manifests/v1") == 1

      # An Accept the upstream can't satisfy is its own answer.
      assert %{status: 404} =
               req(ctx, :head, path, headers: [{"accept", "application/vnd.example+json"}])

      assert FakeRegistry.count_authorized(:registry, "HEAD", "/manifests/v1") == 2
    end

    test "manifests by digest come from the store once fetched", %{ctx: ctx} do
      image = FakeRegistry.put_image("actions/cache", "v4", layers())
      path = "/v2/ghcr.io/actions/cache/manifests/#{image.manifest}"
      assert %{status: 200, body: body} = req(ctx, :get, path)
      assert body == image.manifest_body
      FakeRegistry.clear_requests()

      resp = req(ctx, :get, path)
      assert resp.body == image.manifest_body
      assert resp.headers["docker-content-digest"] == [image.manifest]
      assert resp.headers["content-type"] == [FakeRegistry.manifest_type()]
      assert %{status: 200, body: ""} = req(ctx, :head, path)
      assert FakeRegistry.requests() == []
    end

    test "a stored blob serves ranges", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/busybox", "1", image_layers)
      path = "/v2/docker.io/library/busybox/blobs/#{FakeRegistry.digest(layer)}"
      assert %{status: 200} = req(ctx, :get, path)

      resp = req(ctx, :get, path, headers: [{"range", "bytes=10-19"}])
      assert resp.status == 206
      assert resp.body == binary_part(layer, 10, 10)
      assert resp.headers["content-range"] == ["bytes 10-19/#{byte_size(layer)}"]
    end

    test "HEAD on a blob that isn't stored asks the upstream and stores nothing", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/busybox", "1", image_layers)
      digest = FakeRegistry.digest(layer)
      resp = req(ctx, :head, "/v2/docker.io/library/busybox/blobs/#{digest}")
      assert resp.status == 200
      assert resp.headers["content-length"] == ["#{byte_size(layer)}"]
      assert resp.headers["docker-content-digest"] == [digest]
      assert Store.lookup(digest) == :error
    end
  end

  describe "the anonymous token flow" do
    test "uses the compiled realm, whatever the challenge says, and reuses the token",
         %{ctx: ctx} do
      FakeRegistry.challenge_realm("https://evil.test/token")
      FakeRegistry.put_image("actions/runner", "latest", layers())
      pull(ctx, "ghcr.io", "actions/runner", "latest")

      assert [%{query: query}] = Enum.filter(FakeRegistry.requests(), &(&1.path == "/token"))
      assert query =~ "scope=repository%3Aactions%2Frunner%3Apull"
      assert query =~ "service=fake.test"
    end

    test "fetches a new token when the last one expires", %{ctx: ctx} do
      FakeRegistry.token_ttl(1)
      image = FakeRegistry.put_image("actions/runner", "latest", layers())
      [a, b, c] = [image.config | image.layers]
      assert %{status: 200} = req(ctx, :get, "/v2/ghcr.io/actions/runner/blobs/#{a}")
      assert %{status: 200} = req(ctx, :get, "/v2/ghcr.io/actions/runner/blobs/#{b}")
      assert FakeRegistry.count(:registry, "GET", "/token") == 1
      Process.sleep(1100)
      assert %{status: 200} = req(ctx, :get, "/v2/ghcr.io/actions/runner/blobs/#{c}")
      assert FakeRegistry.count(:registry, "GET", "/token") == 2
    end
  end

  describe "blobs" do
    test "follow the redirect to storage, which never sees a token", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/node", "22", image_layers)
      digest = FakeRegistry.digest(layer)
      resp = req(ctx, :get, "/v2/docker.io/library/node/blobs/#{digest}")
      assert resp.body == layer
      assert resp.headers["docker-content-digest"] == [digest]
      assert resp.headers["content-length"] == ["#{byte_size(layer)}"]

      assert [%{authorization: nil, query: "sig=x"}] =
               Enum.filter(FakeRegistry.requests(), &(&1.server == :storage))

      assert {:ok, %{size: size}} = Store.lookup(digest)
      assert size == byte_size(layer)
    end

    test "TLS to the upstream is verified: a certificate for another name is refused",
         %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/node", "22", image_layers)
      digest = FakeRegistry.digest(layer)
      FakeRegistry.redirect_host(digest, "wrong.test")

      assert %{status: 502} = req(ctx, :get, "/v2/docker.io/library/node/blobs/#{digest}")
      assert Enum.filter(FakeRegistry.requests(), &(&1.server == :storage)) == []
      assert Store.lookup(digest) == :error
    end

    test "identical concurrent fetches are coalesced", %{ctx: ctx} do
      big = :crypto.strong_rand_bytes(1024 * 1024)
      FakeRegistry.put_image("library/postgres", "18", [big])
      digest = FakeRegistry.digest(big)
      FakeRegistry.slow(digest, 20)
      path = "/v2/docker.io/library/postgres/blobs/#{digest}"

      bodies =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> req(ctx, :get, path) end) end)
        |> Task.await_many(30_000)

      assert Enum.all?(bodies, &(&1.status == 200 and &1.body == big))
      assert FakeRegistry.count(:storage, "GET", digest) == 1
    end

    test "a client that doesn't read collects no messages", %{ctx: ctx} do
      big = :crypto.strong_rand_bytes(1024 * 1024)
      FakeRegistry.put_image("library/postgres", "16", [big])
      digest = FakeRegistry.digest(big)
      FakeRegistry.slow(digest, 5)
      host = CrewCache.Allowlist.host_for_prefix("docker.io")
      spec = %{host: host, repo: "library/postgres", digest: digest, kind: :blob, accept: nil}

      assert {:fetching, info} = CrewCache.Fetcher.open(spec)
      assert :ok = wait_until(fn -> Store.lookup(digest) != :error end)
      {:message_queue_len, queued} = Process.info(self(), :message_queue_len)
      assert queued <= 2
      CrewCache.Fetcher.close(info)
      _ = ctx
    end

    test "a download that crashes leaves no temporary file", %{ctx: ctx, tmp_dir: dir} do
      big = :crypto.strong_rand_bytes(1024 * 1024)
      FakeRegistry.put_image("library/postgres", "15", [big])
      digest = FakeRegistry.digest(big)
      FakeRegistry.slow(digest, 50)
      path = "/v2/docker.io/library/postgres/blobs/#{digest}"
      Task.start(fn -> req(ctx, :get, path) end)

      fetcher = wait_for_fetcher(digest)
      wait_until(fn -> :atomics.get(:sys.get_state(fetcher).counter, 1) > 100_000 end)
      Process.exit(:sys.get_state(fetcher).worker, :kill)

      assert :ok = wait_until(fn -> File.ls!(Path.join(dir, "tmp")) == [] end)
      assert %{reserved: 0} = Store.usage()
    end

    @tag cache: [max_fetches: 1]
    test "past max_fetches, a miss is refused rather than queued", %{ctx: ctx} do
      [a, b] = [:crypto.strong_rand_bytes(600_000), :crypto.strong_rand_bytes(1000)]
      FakeRegistry.put_image("library/postgres", "14", [a, b])
      FakeRegistry.slow(FakeRegistry.digest(a), 50)

      slow =
        Task.async(fn ->
          req(ctx, :get, "/v2/docker.io/library/postgres/blobs/#{FakeRegistry.digest(a)}")
        end)

      wait_for_fetcher(FakeRegistry.digest(a))

      assert %{status: 503} =
               req(ctx, :get, "/v2/docker.io/library/postgres/blobs/#{FakeRegistry.digest(b)}")

      assert %{status: 200} = Task.await(slow, 10_000)
    end

    @tag cache: [max_bytes: 1_000_000]
    test "downloads in flight count against the quota", %{ctx: ctx} do
      blobs = for _ <- 1..3, do: :crypto.strong_rand_bytes(400_000)
      FakeRegistry.put_image("library/postgres", "13", blobs)
      for b <- blobs, do: FakeRegistry.slow(FakeRegistry.digest(b), 30)

      statuses =
        blobs
        |> Enum.map(fn b ->
          Task.async(fn ->
            req(ctx, :get, "/v2/docker.io/library/postgres/blobs/#{FakeRegistry.digest(b)}").status
          end)
        end)
        |> Task.await_many(20_000)
        |> Enum.sort()

      # Two fit in 95% of 1 MB; the third would have overrun it.
      assert statuses == [200, 200, 404]
    end

    test "a manifest first asked for as a blob is still served as a manifest", %{ctx: ctx} do
      image = FakeRegistry.put_image("library/busybox", "2", layers())

      assert %{status: 200} =
               req(ctx, :get, "/v2/docker.io/library/busybox/blobs/#{image.manifest}")

      resp = req(ctx, :get, "/v2/docker.io/library/busybox/manifests/#{image.manifest}")
      assert resp.status == 200
      assert resp.headers["content-type"] == [FakeRegistry.manifest_type()]
    end

    test "a fetch that dies cuts its clients short at once", %{ctx: ctx} do
      big = :crypto.strong_rand_bytes(1024 * 1024)
      FakeRegistry.put_image("library/postgres", "17", [big])
      digest = FakeRegistry.digest(big)
      FakeRegistry.slow(digest, 50)
      path = "/v2/docker.io/library/postgres/blobs/#{digest}"

      client =
        Task.async(fn ->
          try do
            req(ctx, :get, path)
          rescue
            e -> e
          end
        end)

      fetcher = wait_for_fetcher(digest)
      wait_until(fn -> :atomics.get(:sys.get_state(fetcher).counter, 1) > 200_000 end)
      Process.exit(fetcher, :kill)
      {time, result} = :timer.tc(fn -> Task.await(client, 10_000) end)

      assert time < 5_000_000
      refute match?(%Req.Response{body: ^big}, result)
      assert Store.lookup(digest) == :error
    end

    test "a digest mismatch stores nothing, counts, and never completes the response",
         %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/redis", "8", image_layers)
      digest = FakeRegistry.digest(layer)
      FakeRegistry.corrupt(digest)

      path = "/v2/docker.io/library/redis/blobs/#{digest}"

      result =
        try do
          req(ctx, :get, path)
        rescue
          e -> e
        end

      # The last byte is held back until the digest checks out.
      case result do
        %Req.Response{body: body} -> assert byte_size(body) < byte_size(layer)
        %{__exception__: true} -> :ok
      end

      assert Store.lookup(digest) == :error
      assert Stats.snapshot().digest_mismatches == 1

      # For a while after, the answer is a 502 (§15.3) without asking the
      # upstream again.
      FakeRegistry.clear_requests()
      assert %{status: 502} = req(ctx, :get, path)
      assert FakeRegistry.requests() == []
      assert Stats.snapshot().digest_mismatches == 1
    end

    test "a manifest whose digest doesn't match is a 502", %{ctx: ctx} do
      image = FakeRegistry.put_image("library/redis", "8", layers())
      FakeRegistry.corrupt(image.manifest)
      assert %{status: 502} = req(ctx, :get, "/v2/docker.io/library/redis/manifests/8")
      assert Store.lookup(image.manifest) == :error
      assert Stats.snapshot().digest_mismatches == 1
    end
  end

  describe "what isn't cached gets a 404, so containerd goes upstream itself" do
    test "a repository outside the allowlist", %{ctx: ctx} do
      FakeRegistry.put_image("someone/tool", "1", layers())
      assert %{status: 404} = req(ctx, :head, "/v2/ghcr.io/someone/tool/manifests/1")
      assert FakeRegistry.requests() == []
    end

    test "a prefix that isn't a compiled host, or a host that isn't enabled", %{ctx: ctx} do
      assert %{status: 404} = req(ctx, :get, "/v2/evil.example/library/x/manifests/1")
      assert %{status: 404} = req(ctx, :get, "/v2/registry-1.docker.io/library/x/manifests/1")

      :ok = CrewCache.Settings.apply(%{"enabled_hosts" => ["ghcr.io"]}) |> elem(0)
      FakeRegistry.put_image("library/alpine", "3", layers())
      assert %{status: 404} = req(ctx, :get, "/v2/docker.io/library/alpine/manifests/3")
      assert FakeRegistry.requests() == []
    end

    test "a private repository under an allowlisted glob", %{ctx: ctx} do
      image = FakeRegistry.put_image("actions/private", "1", layers(), public: false)
      assert %{status: 404} = req(ctx, :get, "/v2/ghcr.io/actions/private/manifests/1")

      assert %{status: 404} =
               req(ctx, :get, "/v2/ghcr.io/actions/private/manifests/#{image.manifest}")

      assert Store.usage().objects == 0
    end

    test "malformed names and references", %{ctx: ctx} do
      assert %{status: 404} = req(ctx, :get, "/v2/ghcr.io/actions/Runner/manifests/1")
      assert %{status: 404} = req(ctx, :get, "/v2/ghcr.io/actions/runner/blobs/latest")
      assert %{status: 404} = req(ctx, :get, "/v2/ghcr.io/actions/runner/tags/list")
      assert %{status: 404} = req(ctx, :get, "/v2/ghcr.io/actions/runner/referrers/sha256:00")
    end
  end

  describe "what the cache must never do (§15.5)" do
    test "store or serve anything with client credentials: they're never sent on",
         %{ctx: ctx} do
      FakeRegistry.put_image("library/alpine", "3.22", layers())
      FakeRegistry.put_image("library/private", "1", layers(), public: false)
      secret = [{"authorization", "Bearer client-secret-value"}]

      log =
        capture_log([level: :debug], fn ->
          Logger.configure(level: :debug)

          assert %{status: 200} =
                   req(ctx, :head, "/v2/docker.io/library/alpine/manifests/3.22", headers: secret)

          assert %{status: 404} =
                   req(ctx, :get, "/v2/docker.io/library/private/manifests/1", headers: secret)

          Logger.configure(level: :warning)
        end)

      for r <- FakeRegistry.requests() do
        refute (r.authorization || "") =~ "client-secret"
      end

      tokens = FakeRegistry.state().tokens |> Map.keys()
      assert tokens != []
      refute log =~ "client-secret"
      for token <- tokens, do: refute(log =~ token)
    end

    test "accept a push: uploads and writes are refused, not forwarded", %{ctx: ctx} do
      base = "/v2/ghcr.io/actions/runner"

      for {method, path} <- [
            post: "/blobs/uploads/",
            put: "/blobs/uploads/x?digest=sha256:#{String.duplicate("a", 64)}",
            patch: "/blobs/uploads/x",
            put: "/manifests/latest",
            delete: "/manifests/sha256:#{String.duplicate("a", 64)}"
          ] do
        assert %{status: 405} = req(ctx, method, base <> path, body: "data")
      end

      assert FakeRegistry.requests() == []
      assert Store.usage().objects == 0
    end

    test "connect to blocked4: a redirect into the LAN is refused", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/nginx", "1", image_layers)
      digest = FakeRegistry.digest(layer)
      FakeRegistry.redirect_host(digest, "lan.test")

      log =
        capture_log(fn ->
          assert %{status: 404} = req(ctx, :get, "/v2/docker.io/library/nginx/blobs/#{digest}")
        end)

      assert log =~ "192.168.1.10"
      assert Enum.filter(FakeRegistry.requests(), &(&1.server == :storage)) == []
      assert Store.lookup(digest) == :error
    end

    @tag cache: [origins: %{"ghcr.io" => "metadata.test:443"}]
    test "connect to blocked4: an upstream whose name resolves there is refused", %{ctx: ctx} do
      log =
        capture_log(fn ->
          assert %{status: status} = req(ctx, :head, "/v2/ghcr.io/actions/runner/manifests/1")
          assert status in [404, 502]
        end)

      assert log =~ "169.254.169.254"
    end

    @tag cache: [site4: ["81.2.3.0/24"]]
    test "connect to site4: a redirect to the site's own address is refused", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/nginx", "1", image_layers)
      digest = FakeRegistry.digest(layer)
      FakeRegistry.redirect_host(digest, "site.test")

      log =
        capture_log(fn ->
          assert %{status: 404} = req(ctx, :get, "/v2/docker.io/library/nginx/blobs/#{digest}")
        end)

      assert log =~ "81.2.3.4"
    end
  end

  describe "TLS" do
    test "serves a leaf from the current chain, and a rotation takes effect at once",
         %{ctx: ctx, tmp_dir: dir} do
      inter =
        File.read!(Path.join([dir, "ca", "intermediate.pem"])) |> Certs.from_pem()

      leaf = peer_leaf(ctx.ports.https)
      assert :public_key.pkix_is_issuer(leaf, inter)

      :ok = CA.rotate()

      new_inter =
        File.read!(Path.join([dir, "ca", "intermediate.pem"])) |> Certs.from_pem()

      new_leaf = peer_leaf(ctx.ports.https)
      refute new_inter == inter
      assert :public_key.pkix_is_issuer(new_leaf, new_inter)
    end

    # Only the root is in the CA file, so this also shows the
    # intermediate is sent in the handshake.
    @tag :openssl
    test "openssl verifies the chain against the root", %{ctx: ctx, tmp_dir: dir} do
      File.write!(Path.join(dir, "root.pem"), CA.root_pem())

      {out, code} =
        System.cmd(
          "sh",
          [
            "-c",
            "openssl s_client -connect 127.0.0.1:#{ctx.ports.https} -CAfile #{dir}/root.pem " <>
              "-verify_ip 127.0.0.1 -verify_return_error </dev/null"
          ],
          stderr_to_stdout: true
        )

      assert code == 0, out
      assert out =~ "Verify return code: 0 (ok)"
    end

    @tag :go
    test "Go's TLS client accepts it, as dockerd and containerd will", %{ctx: ctx, tmp_dir: dir} do
      File.write!(Path.join(dir, "root.pem"), CA.root_pem())

      File.write!(Path.join(dir, "get.go"), """
      package main

      import (
      \t"crypto/tls"
      \t"crypto/x509"
      \t"fmt"
      \t"net/http"
      \t"os"
      )

      func main() {
      \tpem, _ := os.ReadFile("root.pem")
      \tpool := x509.NewCertPool()
      \tpool.AppendCertsFromPEM(pem)
      \tc := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
      \tresp, err := c.Get(os.Args[1])
      \tif err != nil {
      \t\tfmt.Println("error:", err)
      \t\tos.Exit(1)
      \t}
      \tfmt.Println("status:", resp.StatusCode, resp.Header.Get("Docker-Distribution-Api-Version"))
      }
      """)

      {out, code} =
        System.cmd("go", ["run", "get.go", ctx.base <> "/v2/"],
          cd: dir,
          stderr_to_stdout: true,
          env: [{"GO111MODULE", "off"}]
        )

      assert code == 0, out
      assert out =~ "status: 200 registry/2.0"
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp wait_for_fetcher(digest, tries \\ 100) do
    case Registry.lookup(CrewCache.Fetcher.Registry, {:blob, digest}) do
      [{pid, _}] ->
        pid

      [] when tries > 0 ->
        Process.sleep(10)
        wait_for_fetcher(digest, tries - 1)
    end
  end

  # OTP can't verify the chain (CrewCache.CATest), so this only reads it.
  defp peer_leaf(port) do
    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none, active: false], 5000)

    {:ok, leaf} = :ssl.peercert(socket)
    :ssl.close(socket)
    leaf
  end
end
