defmodule CrewCache.MgmtTest do
  use ExUnit.Case, async: false

  import CrewCache.CacheCase

  alias CrewCache.{CA, FakeRegistry, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = tags do
    %{ctx: start_cache(Path.join(dir, "cache"), Map.get(tags, :cache, []))}
  end

  defp mgmt(ctx, method, path, opts \\ []) do
    Req.request!([method: method, url: ctx.mgmt <> path, retry: false] ++ opts)
  end

  defp layers, do: [:crypto.strong_rand_bytes(1000), :crypto.strong_rand_bytes(2000)]

  describe "GET /stats" do
    test "per host counters, evictions, mismatches, the store and the top images", %{ctx: ctx} do
      FakeRegistry.put_image("library/alpine", "3.22", layers())
      pull(ctx, "docker.io", "library/alpine", "3.22")
      pull(ctx, "docker.io", "library/alpine", "3.22")

      %{status: 200, body: body} = mgmt(ctx, :get, "/stats")

      assert Enum.map(body["hosts"], & &1["host"]) == CrewProtocol.Hosts.names()
      hub = Enum.find(body["hosts"], &(&1["host"] == "registry-1.docker.io"))

      assert %{"hits" => 6, "misses" => 4, "mismatches" => 0} = hub
      assert hub["bytes_served"] > 6000
      assert hub["bytes_stored"] == Store.usage().bytes

      assert %{"hits" => 0, "bytes_stored" => 0} =
               Enum.find(body["hosts"], &(&1["host"] == "quay.io"))

      assert body["evictions"] == 0
      assert body["digest_mismatches"] == 0
      assert %{"bytes" => _, "max_bytes" => _, "objects" => 4} = body["store"]

      assert [%{"host" => "registry-1.docker.io", "repo" => "library/alpine", "hits" => 6} = top] =
               body["top"]

      assert top["bytes_served"] == hub["bytes_served"]
    end
  end

  describe "POST /config" do
    test "applies and persists enabled hosts and the allowlist", %{ctx: ctx, tmp_dir: dir} do
      FakeRegistry.put_image("someone/tool", "1", layers())
      assert %{status: 404} = req(ctx, :head, "/v2/ghcr.io/someone/tool/manifests/1")

      config = %{
        "enabled_hosts" => ["ghcr.io"],
        "allowlist" => ["ghcr.io/someone/*"],
        "parent" => nil
      }

      assert %{status: 200, body: %{"ok" => true, "ca_rotated" => false}} =
               mgmt(ctx, :post, "/config", json: config)

      assert %{status: 200} = req(ctx, :head, "/v2/ghcr.io/someone/tool/manifests/1")
      assert %{status: 404} = req(ctx, :head, "/v2/docker.io/library/alpine/manifests/1")

      path = Path.join([dir, "cache", "config.json"])
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      assert %{"enabled_hosts" => ["ghcr.io"], "allowlist" => ["ghcr.io/someone/*"]} =
               File.read!(path) |> Jason.decode!()

      stop_supervised!(CrewCache)
      ctx = start_cache_for(ctx, Path.join(dir, "cache"))
      assert %{status: 200} = req(ctx, :head, "/v2/ghcr.io/someone/tool/manifests/1")
    end

    test "refuses hosts Crew doesn't know and entries that aren't <host>/<glob>", %{ctx: ctx} do
      for {body, message} <- [
            {%{"enabled_hosts" => ["evil.example"]}, "enabled_hosts"},
            {%{"allowlist" => ["evil.example/*"]}, "allowlist"},
            {%{"allowlist" => ["ghcr.io/../x"]}, "allowlist"},
            {%{"parent" => %{"url" => "http://p:5443", "token" => "t", "ca_pem" => "x"}},
             "parent.url"},
            {%{"parent" => %{"url" => "https://p:5443", "token" => "t", "ca_pem" => "x"}},
             "parent.ca_pem"},
            {%{"rotate_ca" => "yes"}, "rotate_ca"},
            {%{"site4" => ["300.0.0.0/8"]}, "site4"},
            {%{"surprise" => 1}, "surprise"}
          ] do
        assert %{status: 422, body: %{"error" => error}} = mgmt(ctx, :post, "/config", json: body)
        assert error =~ message
      end

      assert %{status: 400} =
               mgmt(ctx, :post, "/config",
                 body: "{nope",
                 headers: [{"content-type", "application/json"}]
               )
    end

    test "takes a parent with its pinned CA, and never shows the token back", %{
      ctx: ctx,
      tmp_dir: dir
    } do
      parent = %{
        "url" => "https://parent.test:5443/",
        "token" => "parent-secret",
        "ca_pem" => CA.root_pem()
      }

      assert %{status: 200} = mgmt(ctx, :post, "/config", json: %{"parent" => parent})

      assert %{url: "https://parent.test:5443", token: "parent-secret", cacerts: [_]} =
               CrewCache.Settings.current().parent

      refute inspect(CrewCache.Settings.saved()) =~ "parent-secret"
      # What a crash report would print.
      refute inspect(:sys.get_status(CrewCache.Settings)) =~ "parent-secret"
      assert %{status: 200} = mgmt(ctx, :post, "/config", json: %{"parent" => nil})
      assert CrewCache.Settings.current().parent == nil
      refute File.read!(Path.join([dir, "cache", "config.json"])) =~ "parent-secret"
    end

    test "rotate_ca regenerates the chain", %{ctx: ctx} do
      before = mgmt(ctx, :get, "/ca.pem").body

      assert %{status: 200, body: %{"ca_rotated" => true}} =
               mgmt(ctx, :post, "/config", json: %{"rotate_ca" => true})

      refute mgmt(ctx, :get, "/ca.pem").body == before
    end

    test "site4 from the agent is refused from then on", %{ctx: ctx} do
      [layer | _] = image_layers = layers()
      FakeRegistry.put_image("library/nginx", "1", image_layers)
      digest = FakeRegistry.digest(layer)
      FakeRegistry.redirect_host(digest, "site.test")

      assert %{status: 200} = mgmt(ctx, :post, "/config", json: %{"site4" => ["81.2.3.4/32"]})
      assert %{status: 404} = req(ctx, :get, "/v2/docker.io/library/nginx/blobs/#{digest}")
    end
  end

  describe "POST /purge" do
    setup %{ctx: ctx} do
      FakeRegistry.put_image("library/alpine", "3.22", layers())
      FakeRegistry.put_image("actions/runner", "1", layers())
      pull(ctx, "docker.io", "library/alpine", "3.22")
      pull(ctx, "ghcr.io", "actions/runner", "1")
      :ok
    end

    test "by repository, host or everything", %{ctx: ctx} do
      assert %{status: 200, body: %{"ok" => true, "removed" => 4, "bytes" => bytes}} =
               mgmt(ctx, :post, "/purge", json: %{"scope" => "repo:ghcr.io/actions/runner"})

      assert bytes > 3000
      assert %{objects: 4} = Store.usage()

      assert %{body: %{"removed" => 4}} =
               mgmt(ctx, :post, "/purge", json: %{"scope" => "host:registry-1.docker.io"})

      assert %{body: %{"removed" => 0}} = mgmt(ctx, :post, "/purge", json: %{"scope" => "all"})
      assert %{objects: 0} = Store.usage()
    end

    test "refuses a scope it can't read", %{ctx: ctx} do
      for scope <- ["host:evil.example", "repo:ghcr.io", "repo:ghcr.io/../x", "everything", nil] do
        assert %{status: 422} = mgmt(ctx, :post, "/purge", json: %{"scope" => scope})
      end
    end
  end

  test "POST /evict evicts to a target", %{ctx: ctx} do
    FakeRegistry.put_image("library/alpine", "3.22", layers())
    pull(ctx, "docker.io", "library/alpine", "3.22")

    assert %{status: 200, body: %{"ok" => true, "evicted" => n, "store_bytes" => 0}} =
             mgmt(ctx, :post, "/evict", json: %{"target_bytes" => 0})

    assert n == 4
    assert %{status: 422} = mgmt(ctx, :post, "/evict", json: %{"target_bytes" => -1})
  end

  test "GET /ca.pem is the root", %{ctx: ctx, tmp_dir: dir} do
    resp = mgmt(ctx, :get, "/ca.pem")
    assert resp.status == 200
    assert resp.headers["content-type"] == ["application/x-pem-file"]
    assert resp.body == File.read!(Path.join([dir, "cache", "ca", "root.pem"]))
    assert resp.body == CA.root_pem()
  end

  describe "GET /host" do
    @tag cache: [host_root: "/nonexistent-crew-host-root"]
    test "absent files are false, [] and null", %{ctx: ctx} do
      assert %{
               status: 200,
               body: %{"reboot_required" => false, "packages" => [], "boot_id" => nil}
             } =
               mgmt(ctx, :get, "/host")
    end

    test "reads /run/reboot-required* and the boot id", %{ctx: ctx, tmp_dir: dir} do
      root = Path.join(dir, "host")
      File.mkdir_p!(Path.join(root, "run"))
      File.mkdir_p!(Path.join(root, "proc/sys/kernel/random"))
      File.write!(Path.join(root, "run/reboot-required"), "*** System restart required ***\n")

      File.write!(
        Path.join(root, "run/reboot-required.pkgs"),
        "linux-image\nlibc6\nlinux-image\n"
      )

      File.write!(
        Path.join(root, "proc/sys/kernel/random/boot_id"),
        "0b7e6a52-0000-4000-8000-000000000001\n"
      )

      stop_supervised!(CrewCache)
      ctx = start_cache_for(ctx, Path.join(dir, "cache2"), host_root: root)

      assert %{
               "reboot_required" => true,
               "packages" => ["linux-image", "libc6"],
               "boot_id" => "0b7e6a52-0000-4000-8000-000000000001"
             } = mgmt(ctx, :get, "/host").body
    end
  end

  test "unknown paths are 404 and wrong methods 405", %{ctx: ctx} do
    assert %{status: 404} = mgmt(ctx, :get, "/nope")
    assert %{status: 405} = mgmt(ctx, :post, "/stats")
    assert %{status: 405} = mgmt(ctx, :get, "/config")
  end

  describe "with a token" do
    @tag cache: [mgmt_token: "mgmt-secret-token"]
    test "every endpoint needs it", %{ctx: ctx} do
      for path <- ~w(/stats /ca.pem /host) do
        assert %{status: 401} = mgmt(ctx, :get, path)
        assert %{status: 401} = mgmt(ctx, :get, path, auth: {:bearer, "wrong"})
        assert %{status: 200} = mgmt(ctx, :get, path, auth: {:bearer, "mgmt-secret-token"})
      end

      assert %{status: 401} = mgmt(ctx, :post, "/config", json: %{"rotate_ca" => true})
    end
  end
end
