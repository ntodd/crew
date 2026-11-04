defmodule CrewCache.ParentTest do
  use ExUnit.Case, async: false

  import CrewCache.CacheCase

  alias CrewCache.{FakeParent, FakeRegistry, Settings, Stats, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    ctx = start_cache(dir, parent_first_byte_ms: 300)
    parent = FakeParent.start()

    {:ok, _} =
      Settings.apply(%{
        "parent" => %{"url" => parent.url, "token" => "box-token-1", "ca_pem" => parent.ca_pem}
      })

    image = FakeRegistry.put_image("library/alpine", "3.22", [:crypto.strong_rand_bytes(5000)])
    state = FakeRegistry.state()

    FakeParent.put(
      Map.merge(
        Map.new(image.layers ++ [image.config], &{&1, state.blobs[&1]}),
        %{image.manifest => image.manifest_body}
      )
    )

    %{ctx: ctx, parent: parent, image: image}
  end

  defp upstream_fetches,
    do: Enum.reject(FakeRegistry.requests(), &(&1.method == "HEAD" or &1.path == "/token"))

  test "by-digest fetches go to the parent first, with the box's token", %{ctx: ctx, image: image} do
    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        Logger.configure(level: :debug)
        pull(ctx, "docker.io", "library/alpine", "3.22")
        Logger.configure(level: :warning)
      end)

    refute log =~ "box-token-1"

    assert upstream_fetches() == []

    paths = Enum.map(FakeParent.requests(), & &1.path)
    assert "/v2/docker.io/library/alpine/manifests/#{image.manifest}" in paths
    assert "/v2/docker.io/library/alpine/blobs/#{hd(image.layers)}" in paths
    assert Enum.all?(FakeParent.requests(), &(&1.authorization == "Bearer box-token-1"))
    assert {:ok, _} = Store.lookup(hd(image.layers))
  end

  test "tags are never resolved through the parent (§15.5)", %{ctx: ctx} do
    pull(ctx, "docker.io", "library/alpine", "3.22")
    refute Enum.any?(FakeParent.requests(), &String.ends_with?(&1.path, "/manifests/3.22"))
    assert FakeRegistry.count_authorized(:registry, "HEAD", "/manifests/3.22") == 1
  end

  test "an erroring parent means the upstream", %{ctx: ctx, image: image} do
    FakeParent.mode({:status, 500})
    result = pull(ctx, "docker.io", "library/alpine", "3.22")
    assert {hd(image.layers), FakeRegistry.state().blobs[hd(image.layers)]} in result.blobs
    assert FakeRegistry.count(:storage, "GET", hd(image.layers)) == 1
  end

  test "a parent slower than the first-byte limit means the upstream", %{ctx: ctx, image: image} do
    FakeParent.mode({:slow, 2000})
    {time, _} = :timer.tc(fn -> pull(ctx, "docker.io", "library/alpine", "3.22") end)
    assert FakeRegistry.count(:storage, "GET", hd(image.layers)) == 1
    assert time < 8_000_000
  end

  test "the box verifies what the parent sends", %{ctx: ctx, image: image} do
    FakeParent.mode(:corrupt)
    layer = hd(image.layers)
    path = "/v2/docker.io/library/alpine/blobs/#{layer}"

    result =
      try do
        req(ctx, :get, path)
      rescue
        e -> e
      end

    case result do
      %Req.Response{body: body} -> assert byte_size(body) < 5000
      %{__exception__: true} -> :ok
    end

    assert Store.lookup(layer) == :error
    assert Stats.snapshot().digest_mismatches == 1

    # The next try skips the parent for that digest.
    Process.sleep(50)
    assert wait_for_retry(ctx, path).status == 200
    assert {:ok, _} = Store.lookup(layer)
    assert FakeRegistry.count(:storage, "GET", layer) == 1
  end

  test "the parent's certificate must chain to its pinned CA", %{
    ctx: ctx,
    parent: parent,
    image: image
  } do
    other = CrewCache.CA.root_pem()

    {:ok, _} =
      Settings.apply(%{
        "parent" => %{"url" => parent.url, "token" => "box-token-1", "ca_pem" => other}
      })

    pull(ctx, "docker.io", "library/alpine", "3.22")
    assert FakeRegistry.count(:storage, "GET", hd(image.layers)) == 1
    assert FakeParent.requests() == []
  end

  # A failed fetch lingers (CrewCache.Fetcher); the retry waits it out.
  defp wait_for_retry(ctx, path, tries \\ 60) do
    case req(ctx, :get, path) do
      %{status: 502} when tries > 0 ->
        Process.sleep(100)
        wait_for_retry(ctx, path, tries - 1)

      resp ->
        resp
    end
  end
end
