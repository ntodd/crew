defmodule CrewAgent.ImagesTest do
  @moduledoc """
  `image.prepare` on a real driver (§13.1): a local HTTP server serves
  the kernel and the compressed root filesystem, and the manifest is
  signed with a key made for the test.
  """
  use ExUnit.Case, async: false

  import Bitwise
  import CrewAgent.TestEvents

  alias CrewAgent.{Config, Identity, Images}
  alias CrewProtocol.Auth

  defmodule Files do
    @moduledoc false
    # Serves `/<name>` from what the test registered in an Agent:
    # `%{body: binary | {:file, path}, script: [step]}`. Each request takes
    # the next script step (`:fail` answers 503, `{:short, n}` sends only
    # the first n bytes, `{:extra, bin}` appends bytes, `{:redirect, url}`
    # answers 302); with none left it serves the file, honouring
    # `Range: bytes=N-`.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{agent: agent, test: test}) do
      name = String.trim_leading(conn.request_path, "/")
      range = conn |> get_req_header("range") |> List.first()
      agent_id = conn |> get_req_header("x-crew-agent-id") |> List.first()
      send(test, {:request, name, range, agent_id})

      case Agent.get_and_update(agent, &next(&1, name)) do
        nil -> send_resp(conn, 404, "not found")
        {_file, :fail} -> send_resp(conn, 503, "busy")
        {%{body: body}, {:short, n}} -> send_resp(conn, 200, binary_part(body, 0, n))
        {%{body: body}, {:extra, more}} -> send_resp(conn, 200, body <> more)
        {_file, {:redirect, to}} -> conn |> put_resp_header("location", to) |> send_resp(302, "")
        {%{body: body}, nil} -> serve(conn, body, offset(range))
      end
    end

    defp next(files, name) do
      case files[name] do
        nil -> {nil, files}
        %{script: [step | rest]} = f -> {{f, step}, Map.put(files, name, %{f | script: rest})}
        f -> {{f, nil}, files}
      end
    end

    defp offset("bytes=" <> spec), do: spec |> String.trim_trailing("-") |> String.to_integer()
    defp offset(_), do: 0

    defp serve(conn, {:file, path}, offset) do
      size = File.stat!(path).size

      if offset > 0,
        do:
          conn
          |> put_resp_header("content-range", "bytes #{offset}-#{size - 1}/#{size}")
          |> send_file(206, path, offset, size - offset),
        else: send_file(conn, 200, path)
    end

    defp serve(conn, body, offset) when offset > 0 do
      size = byte_size(body)

      conn
      |> put_resp_header("content-range", "bytes #{offset}-#{size - 1}/#{size}")
      |> send_resp(206, binary_part(body, offset, size - offset))
    end

    defp serve(conn, body, _offset), do: send_resp(conn, 200, body)
  end

  @fast [retry_delay_ms: 10, progress_ms: 0]

  setup do
    attach()
    data_dir = Path.join(System.tmp_dir!(), "crew-images-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_dir) end)

    agent = start_supervised!({Agent, fn -> %{} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Files, %{agent: agent, test: self()}},
         scheme: :http,
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {public, private} = Auth.generate_keypair()

    %{
      config: %Config{driver: "vz", data_dir: data_dir, release_public_key: public},
      private: private,
      agent: agent,
      base: "http://127.0.0.1:#{port}"
    }
  end

  describe "a prepare that succeeds" do
    test "lays out the image read-only, with the ready marker, reporting as it goes", ctx do
      f = fixture(ctx)

      assert :ok = Images.prepare(f.image, ctx.config, @fast)

      d = Images.dir(ctx.config, f.image.id)
      assert File.read!(Path.join(d, "kernel")) == f.kernel
      assert File.read!(Path.join(d, "rootfs.ext4")) == f.ext4
      assert File.read!(Path.join(d, "manifest.json")) == f.manifest
      assert File.read!(Path.join(d, "manifest.sig")) == f.signature
      assert File.exists?(Path.join(d, "ready"))
      assert (File.stat!(Path.join(d, "rootfs.ext4")).mode &&& 0o777) == 0o444
      assert Images.ready?(ctx.config, f.image.id)
      assert [%{id: id, state: "ready"}] = Images.inventory(ctx.config)
      assert id == f.image.id
      assert File.ls!(Config.images_dir(ctx.config)) == [f.image.id]

      events = image_events(f.image.id)
      states = events |> Enum.map(& &1.state) |> Enum.dedup()
      assert states == ~w(downloading verifying converting ready)

      for {_state, group} <- Enum.chunk_by(events, & &1.state) do
        progress = Enum.map(group, & &1.progress)
        assert progress == Enum.sort(progress)
        assert Enum.all?(progress, &(&1 in 0..100))
      end

      assert List.last(events).progress == 100
      assert Enum.any?(events, &(&1.state == "downloading" and &1.progress == 100))
    end

    test "an image that's already ready is reported ready at once", ctx do
      f = fixture(ctx)
      assert :ok = Images.prepare(f.image, ctx.config, @fast)
      image_events(f.image.id)
      flush_requests()

      assert :ok = Images.prepare(f.image, ctx.config, @fast)
      assert [%{state: "ready", progress: 100}] = image_events(f.image.id)
      refute_received {:request, _, _, _}
    end

    test "transient failures are retried, resuming the download where it stopped", ctx do
      f = fixture(ctx)
      script(ctx, "kernel", [:fail, :fail])
      script(ctx, "rootfs", [{:short, 1000}])

      assert :ok = Images.prepare(f.image, ctx.config, @fast)
      assert File.read!(Path.join(Images.dir(ctx.config, f.image.id), "rootfs.ext4")) == f.ext4

      assert_received {:request, "kernel", nil, _}
      assert_received {:request, "kernel", nil, _}
      assert_received {:request, "kernel", nil, _}
      assert_received {:request, "rootfs", nil, _}
      assert_received {:request, "rootfs", "bytes=1000-", _}
    end

    test "a part left by a prepare that was killed is resumed", ctx do
      f = fixture(ctx)
      tmp = Images.tmp_dir(ctx.config, f.image.id)
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "rootfs.ext4.zst.part"), binary_part(f.zst, 0, 500))
      File.write!(Path.join(tmp, "stray"), "left over")

      assert :ok = Images.prepare(f.image, ctx.config, @fast)
      assert_received {:request, "rootfs", "bytes=500-", _}
      refute File.exists?(tmp)
    end

    test "downloads from the control plane carry the agent's signed headers, a redirect elsewhere doesn't",
         ctx do
      agent_id = CrewProtocol.uuid7()
      write_identity(ctx.config, agent_id)
      config = %{ctx.config | url: String.replace(ctx.base, "http:", "ws:") <> "/agent/websocket"}
      f = fixture(ctx)
      elsewhere = String.replace(ctx.base, "127.0.0.1", "localhost") <> "/kernel"
      script(ctx, "kernel", [{:redirect, elsewhere}])

      assert :ok = Images.prepare(f.image, config, @fast)
      assert_received {:request, "kernel", _, ^agent_id}
      assert_received {:request, "kernel", _, nil}
      assert_received {:request, "rootfs", _, ^agent_id}
    end
  end

  describe "a prepare that fails" do
    test "without a release key, before downloading anything", ctx do
      f = fixture(ctx)

      assert {:error, "no_release_key", message} =
               Images.prepare(f.image, %{ctx.config | release_public_key: nil}, @fast)

      assert message =~ "CREW_RELEASE_PUBLIC_KEY"
      assert_failed(ctx, f, "CREW_RELEASE_PUBLIC_KEY")
      refute_received {:request, _, _, _}
    end

    test "on a manifest signed with another key", ctx do
      f = fixture(ctx, sign_with: elem(Auth.generate_keypair(), 1))

      assert {:error, "bad_signature", _} = Images.prepare(f.image, ctx.config, @fast)
      assert_failed(ctx, f, "signature")
      refute_received {:request, _, _, _}
    end

    test "when the manifest and the command disagree", ctx do
      for {key, value} <- [
            {"kernel_size", 1},
            {"rootfs_sha256", String.duplicate("a", 64)},
            {"version", "9.9.9"},
            {"arch", "x64"}
          ] do
        f = fixture(ctx, manifest: %{key => value})

        assert {:error, "manifest_mismatch", message} =
                 Images.prepare(f.image, ctx.config, @fast)

        assert message =~ key |> String.split("_") |> hd()
        assert_failed(ctx, f, "manifest")
      end

      refute_received {:request, _, _, _}
    end

    test "on a kernel that doesn't match its SHA-256", ctx do
      f = fixture(ctx)
      serve(ctx, "kernel", :crypto.strong_rand_bytes(byte_size(f.kernel)))

      assert {:error, "checksum_mismatch", message} = Images.prepare(f.image, ctx.config, @fast)
      assert message =~ "kernel"
      assert_failed(ctx, f, "kernel")
    end

    test "on a root filesystem that doesn't decompress to its SHA-256", ctx do
      f = fixture(ctx, manifest: %{"rootfs_ext4_sha256" => String.duplicate("b", 64)})

      assert {:error, "checksum_mismatch", message} = Images.prepare(f.image, ctx.config, @fast)
      assert message =~ "rootfs.ext4"
      assert_failed(ctx, f, "rootfs.ext4")
    end

    test "on a root filesystem that isn't zstd", ctx do
      f = fixture(ctx, zst: :crypto.strong_rand_bytes(4096))

      assert {:error, "convert_failed", message} = Images.prepare(f.image, ctx.config, @fast)
      assert message =~ "decompressing"
      assert_failed(ctx, f, "decompressing")
    end

    test "when the server sends more than the expected size", ctx do
      f = fixture(ctx)
      script(ctx, "kernel", [{:extra, "more"}])

      assert {:error, "download_failed", message} = Images.prepare(f.image, ctx.config, @fast)
      assert message =~ "more than"
      assert_failed(ctx, f, "more than")
      assert_received {:request, "kernel", _, _}
      refute_received {:request, "kernel", _, _}
    end

    test "when the server keeps failing", ctx do
      f = fixture(ctx)
      script(ctx, "kernel", List.duplicate(:fail, 10))

      assert {:error, "download_failed", message} = Images.prepare(f.image, ctx.config, @fast)
      assert message =~ "503"
      assert_failed(ctx, f, "503")
    end

    test "without room for the image", ctx do
      f = fixture(ctx)
      opts = Keyword.put(@fast, :free_bytes, fn _dir -> {:ok, 1 <<< 30} end)

      assert {:error, "no_space", message} = Images.prepare(f.image, ctx.config, opts)
      assert message =~ "free"
      assert_failed(ctx, f, "free")
      refute_received {:request, _, _, _}
    end
  end

  test "a prepare sweeps other images' abandoned temp dirs, not a live one", ctx do
    stale = Images.tmp_dir(ctx.config, CrewProtocol.uuid7())
    live = Images.tmp_dir(ctx.config, CrewProtocol.uuid7())
    for d <- [stale, live], do: File.mkdir_p!(d) && File.write!(Path.join(d, "rootfs.part"), "x")
    old = System.os_time(:second) - 3600
    File.touch!(Path.join(stale, "rootfs.part"), old)
    File.touch!(stale, old)

    Images.sweep(ctx.config, CrewProtocol.uuid7())
    refute File.exists?(stale)
    assert File.exists?(live)
  end

  # The image build's output directory (images/guest/out/<arch>) holds
  # `Image` beside `kernel/`, the kernel build's directory.
  test "a development image dir: the kernel is a file, not the kernel build's directory", ctx do
    src = Path.join(ctx.config.data_dir, "out")
    File.mkdir_p!(Path.join(src, "kernel"))
    File.write!(Path.join(src, "Image"), "the kernel")
    File.write!(Path.join(src, "rootfs.ext4"), "the rootfs")
    config = %{ctx.config | dev: true, dev_image_dir: src}
    id = CrewProtocol.uuid7()

    assert :ok = Images.prepare(%{id: id, version: "0.0.0-dev", arch: "arm64"}, config)
    assert File.read!(Images.kernel(config, id)) == "the kernel"
    assert Images.ready?(config, id)
  end

  test "the inventory and ready? never see a prepare in progress", ctx do
    id = CrewProtocol.uuid7()
    tmp = Images.tmp_dir(ctx.config, id)
    File.mkdir_p!(tmp)
    for f <- ["kernel", "rootfs.ext4", "ready"], do: File.write!(Path.join(tmp, f), "")

    refute CrewProtocol.uuid?(Path.basename(tmp))
    assert Images.inventory(ctx.config) == []
    refute Images.ready?(ctx.config, id)
  end

  describe "the real guest image" do
    @key_file Path.expand("../../../../images/guest/keys/test-signing.pub", __DIR__)

    if !System.get_env("CREW_REAL_IMAGE_DIR"),
      do: @tag(skip: "set CREW_REAL_IMAGE_DIR to a guest image's release directory")

    @tag :real_image
    @tag timeout: 900_000
    test "downloads, verifies and decompresses (a --long=27 frame)", ctx do
      dir = System.fetch_env!("CREW_REAL_IMAGE_DIR")
      [manifest_path] = Path.wildcard(Path.join(dir, "*.manifest.json"))
      base = String.replace_suffix(manifest_path, ".manifest.json", "")
      manifest = File.read!(manifest_path)
      m = Jason.decode!(manifest)
      key = System.get_env("CREW_REAL_IMAGE_KEY") || @key_file |> File.read!() |> last_line()
      config = %{ctx.config | release_public_key: Base.decode64!(key)}

      for {name, path} <- [{"kernel", base <> ".kernel"}, {"rootfs", base <> ".rootfs.ext4.zst"}],
          do: serve(ctx, name, {:file, path})

      image =
        command_image(%{
          "id" => CrewProtocol.uuid7(),
          "version" => m["version"],
          "arch" => m["arch"],
          "kernel" => ref(ctx, "kernel", m["kernel_sha256"], m["kernel_size"]),
          "rootfs" => ref(ctx, "rootfs", m["rootfs_sha256"], m["rootfs_size"]),
          "manifest" => Base.encode64(manifest),
          "signature" => String.trim(File.read!(base <> ".manifest.sig"))
        })

      {us, result} = :timer.tc(fn -> Images.prepare(image, config) end)
      IO.puts("\nprepared the real image in #{Float.round(us / 1_000_000, 1)} s")

      assert result == :ok
      rootfs = Path.join(Images.dir(config, image.id), "rootfs.ext4")
      assert File.stat!(rootfs).size == m["rootfs_ext4_size"]

      events = image_events(image.id)
      IO.puts("image.state events: #{inspect(Enum.map(events, &{&1.state, &1.progress}))}")

      assert events |> Enum.map(& &1.state) |> Enum.dedup() ==
               ~w(downloading verifying converting ready)
    end
  end

  # -- fixtures --------------------------------------------------------------------

  defp fixture(ctx, opts \\ []) do
    kernel = :crypto.strong_rand_bytes(96 * 1024)

    # Compressible, like a filesystem: random blocks among empty ones.
    ext4 =
      for i <- 1..512, into: "" do
        if rem(i, 3) == 0, do: :crypto.strong_rand_bytes(4096), else: <<0::size(4096 * 8)>>
      end

    zst =
      Keyword.get_lazy(opts, :zst, fn -> ext4 |> :zstd.compress() |> IO.iodata_to_binary() end)

    fields =
      Map.merge(
        %{
          "version" => "0.1.0-dev",
          "arch" => "arm64",
          "kernel_sha256" => sha(kernel),
          "kernel_size" => byte_size(kernel),
          "rootfs_sha256" => sha(zst),
          "rootfs_size" => byte_size(zst),
          "rootfs_ext4_sha256" => sha(ext4),
          "rootfs_ext4_size" => byte_size(ext4),
          "kernel_version" => "6.18.60-crew",
          "runner_version" => "2.338.2",
          "docker_version" => "29.9.2",
          "packages_lock_sha256" => String.duplicate("c", 64),
          "disable_update" => true
        },
        Keyword.get(opts, :manifest, %{})
      )

    manifest = Jason.encode!(fields, pretty: true) <> "\n"
    signature = Auth.sign_manifest(manifest, Keyword.get(opts, :sign_with, ctx.private))
    serve(ctx, "kernel", kernel)
    serve(ctx, "rootfs", zst)

    image =
      command_image(%{
        "id" => CrewProtocol.uuid7(),
        "version" => "0.1.0-dev",
        "arch" => "arm64",
        "kernel" => ref(ctx, "kernel", sha(kernel), byte_size(kernel)),
        "rootfs" => ref(ctx, "rootfs", sha(zst), byte_size(zst)),
        "manifest" => Base.encode64(manifest),
        "signature" => signature
      })

    %{
      image: image,
      kernel: kernel,
      ext4: ext4,
      zst: zst,
      manifest: manifest,
      signature: signature
    }
  end

  defp command_image(image) do
    {:ok, cmd} = CrewProtocol.Command.new("image.prepare", %{"image" => image})
    cmd.payload.image
  end

  defp ref(ctx, name, sha, size),
    do: %{"url" => "#{ctx.base}/#{name}", "sha256" => sha, "size" => size}

  defp serve(ctx, name, body),
    do: Agent.update(ctx.agent, &Map.put(&1, name, %{body: body, script: []}))

  defp script(ctx, name, steps),
    do: Agent.update(ctx.agent, &update_in(&1[name], fn f -> %{f | script: steps} end))

  defp sha(bin), do: :sha256 |> :crypto.hash(bin) |> Base.encode16(case: :lower)

  defp last_line(text), do: text |> String.split("\n", trim: true) |> List.last()

  defp image_events(id) do
    collect_until(fn
      %{type: "image.state", payload: %{image_id: ^id, state: s}} -> s in ~w(ready failed)
      _ -> false
    end)
    |> Enum.filter(&(&1.type == "image.state" and &1.payload.image_id == id))
    |> Enum.map(& &1.payload)
  end

  defp assert_failed(ctx, f, error) do
    last = f.image.id |> image_events() |> List.last()
    assert %{state: "failed"} = last
    assert last.error =~ error
    refute Images.ready?(ctx.config, f.image.id)
    refute File.exists?(Images.dir(ctx.config, f.image.id))
    refute File.exists?(Images.tmp_dir(ctx.config, f.image.id))
  end

  defp write_identity(config, agent_id) do
    identity = %Identity{agent_id: agent_id, private_key: elem(Auth.generate_keypair(), 1)}
    :ok = Identity.save(Config.agent_dir(config), identity)
  end

  defp flush_requests do
    receive do
      {:request, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
