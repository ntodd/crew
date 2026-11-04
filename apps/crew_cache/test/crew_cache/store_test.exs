defmodule CrewCache.StoreTest do
  use ExUnit.Case, async: false

  alias CrewCache.{Stats, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    start_supervised!(Stats)
    start_supervised!({Store, dir: dir, max_bytes: 1000})
    :ok
  end

  defp put(body, meta \\ %{}) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    tmp = Store.tmp_path()
    File.write!(tmp, body)

    meta =
      Map.merge(
        %{
          kind: :blob,
          media_type: nil,
          host: "ghcr.io",
          repo: "actions/runner",
          size: byte_size(body)
        },
        meta
      )

    :ok = Store.commit(tmp, digest, meta)
    digest
  end

  test "commits under blobs/sha256/<2>/<64> and finds it again", %{tmp_dir: dir} do
    digest = put("hello")
    "sha256:" <> hex = digest
    path = Path.join([dir, "blobs", "sha256", binary_part(hex, 0, 2), hex])
    assert File.read!(path) == "hello"
    assert {:ok, %{path: ^path, size: 5, kind: :blob}} = Store.lookup(digest)
    assert Store.lookup("sha256:" <> String.duplicate("0", 64)) == :error
  end

  test "keeps a manifest's media type" do
    digest =
      put(~s({"schemaVersion":2}), %{
        kind: :manifest,
        media_type: "application/vnd.oci.image.index.v1+json"
      })

    assert {:ok, %{kind: :manifest, media_type: "application/vnd.oci.image.index.v1+json"}} =
             Store.lookup(digest)
  end

  test "the index survives a restart", %{tmp_dir: dir} do
    digest = put("persist me")
    stop_supervised!(Store)
    start_supervised!({Store, dir: dir, max_bytes: 1000})
    assert {:ok, %{size: 10}} = Store.lookup(digest)
    assert %{bytes: 10, objects: 1} = Store.usage()
  end

  test "a restart forgets objects whose file is gone and clears tmp/", %{tmp_dir: dir} do
    digest = put("vanishing")
    {:ok, %{path: path}} = Store.lookup(digest)
    File.rm!(path)
    leftover = Store.tmp_path()
    File.write!(leftover, "partial")

    stop_supervised!(Store)
    start_supervised!({Store, dir: dir, max_bytes: 1000})

    assert Store.lookup(digest) == :error
    refute File.exists?(leftover)
    assert %{bytes: 0} = Store.usage()
  end

  describe "the quota (§15.3)" do
    test "past 95% it evicts least recently accessed down to 85%" do
      a = put(String.duplicate("a", 300))
      b = put(String.duplicate("b", 300))
      c = put(String.duplicate("c", 300))
      Store.touch(a)
      # 1200 > 950: b goes (least recent), then c, leaving a and d (600 <= 850).
      d = put(String.duplicate("d", 300))

      assert {:ok, _} = Store.lookup(a)
      assert Store.lookup(b) == :error
      assert Store.lookup(c) == :error
      assert {:ok, _} = Store.lookup(d)
      assert %{bytes: 600, objects: 2} = Store.usage()
      assert Stats.snapshot().evictions == 2
    end

    test "evict_to/1 evicts least recent first down to a target" do
      a = put(String.duplicate("a", 200))
      b = put(String.duplicate("b", 200))
      Store.touch(a)
      assert {:ok, %{evicted: 1, bytes: 200}} = Store.evict_to(250)
      assert {:ok, _} = Store.lookup(a)
      assert Store.lookup(b) == :error
    end
  end

  describe "purge/1" do
    setup do
      %{
        a: put("a", %{host: "ghcr.io", repo: "actions/runner"}),
        b: put("b", %{host: "ghcr.io", repo: "actions/other"}),
        c: put("c", %{host: "registry-1.docker.io", repo: "library/alpine"})
      }
    end

    test "by repository", %{a: a, b: b, c: c} do
      assert {:ok, %{removed: 1, bytes: 1}} = Store.purge({:repo, "ghcr.io", "actions/runner"})
      assert Store.lookup(a) == :error
      assert {:ok, _} = Store.lookup(b)
      assert {:ok, _} = Store.lookup(c)
    end

    test "by host", %{a: a, b: b, c: c} do
      assert {:ok, %{removed: 2}} = Store.purge({:host, "ghcr.io"})
      assert Store.lookup(a) == :error
      assert Store.lookup(b) == :error
      assert {:ok, %{path: path}} = Store.lookup(c)
      assert File.exists?(path)
    end

    test "everything", %{a: a} do
      assert {:ok, %{removed: 3}} = Store.purge(:all)
      assert Store.lookup(a) == :error
      assert %{bytes: 0, objects: 0} = Store.usage()
    end
  end

  test "usage/0 reports bytes per host" do
    put("aa", %{host: "ghcr.io"})
    put("bbb", %{host: "quay.io"})

    assert %{bytes: 5, max_bytes: 1000, by_host: %{"ghcr.io" => 2, "quay.io" => 3}} =
             Store.usage()
  end
end
