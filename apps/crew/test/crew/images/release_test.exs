defmodule Crew.Images.ReleaseTest do
  @moduledoc "Registering signed guest images and mirroring their files (§13.1, §20.1, §20.4)."
  use Crew.DataCase, async: false
  use Oban.Testing, repo: Crew.Repo

  import Crew.ImageFixtures

  alias Crew.Images
  alias Crew.Images.{Image, Mirror}

  setup do
    key = keypair()
    trust(key)
    dir = Path.join(System.tmp_dir!(), "crew-images-#{System.unique_integer([:positive])}")
    store = Path.join(dir, "store")
    previous = Application.get_env(:crew, :image_dir)
    Application.put_env(:crew, :image_dir, store)

    on_exit(fn ->
      Application.put_env(:crew, :image_dir, previous)
      File.rm_rf!(dir)
    end)

    %{key: key, dir: dir, store: store}
  end

  describe "registering" do
    test "a signed manifest is registered, waiting for its files", %{key: key} do
      r = release(key)
      assert {:ok, %Image{} = image} = Images.register_signed(r.manifest, r.signature)

      assert image.version == "1.2.0" and image.arch == "arm64"
      assert image.kernel_sha256 == sha(r.kernel) and image.kernel_size == byte_size(r.kernel)
      assert image.rootfs_sha256 == sha(r.rootfs)
      assert image.rootfs_ext4_size > 0 and image.runner_version == "2.338.2"
      assert image.kernel_version == "6.18.60-crew"
      assert image.manifest == r.manifest and image.signature == r.signature
      assert image.mirror_state == "pending"
      assert_enqueued(worker: Mirror, args: %{"image_id" => image.id})
    end

    test "a bad signature, or no release key, registers nothing", %{key: key} do
      r = release(key)
      other = keypair()

      assert {:error, :bad_signature} =
               Images.register_signed(
                 r.manifest,
                 CrewProtocol.Auth.sign_manifest(r.manifest, other.private)
               )

      assert {:error, :bad_signature} = Images.register_signed(r.manifest <> " ", r.signature)
      Application.put_env(:crew, :release_public_key, nil)
      assert {:error, :no_release_key} = Images.register_signed(r.manifest, r.signature)
      assert Repo.aggregate(Image, :count) == 0
    end

    test "a manifest missing what a box needs is refused", %{key: key} do
      manifest = Jason.encode!(%{"version" => "1.0.0", "arch" => "sparc"})
      sig = CrewProtocol.Auth.sign_manifest(manifest, key.private)
      assert {:error, {:manifest, _}} = Images.register_signed(manifest, sig)
    end

    test "the same release again is the same image; a different one under its version is refused",
         %{key: key} do
      r = release(key)
      {:ok, image} = Images.register_signed(r.manifest, r.signature)
      assert {:ok, %{id: id}} = Images.register_signed(r.manifest, r.signature)
      assert id == image.id

      other = release(key)
      assert {:error, :conflict} = Images.register_signed(other.manifest, other.signature)
    end

    test "the control plane's bundled manifests are registered at boot", %{key: key, dir: dir} do
      bundle = Path.join(dir, "bundle")
      release(key, dir: bundle, version: "1.0.0", files: false)
      release(key, dir: bundle, version: "1.1.0", arch: "x64", files: false)
      File.write!(Path.join(bundle, "crew-guest-9.9.9-arm64.manifest.json"), "{}")

      assert %{registered: 2, failed: [_]} = Images.register_bundle(bundle)
      assert Repo.aggregate(Image, :count) == 2
    end
  end

  describe "defaults" do
    test "only an image whose files are mirrored can be the default", %{key: key} do
      {:ok, old} = register(key, "1.0.0")
      mirrored(old)
      {:ok, new} = register(key, "1.1.0")

      assert Images.defaults()["arm64"].default == old.id
      mirrored(new)
      assert Images.defaults()["arm64"].default == new.id
    end
  end

  describe "mirroring" do
    test "the files come from the release and are checked", %{key: key, store: store} do
      r = release(key)
      {:ok, image} = Images.register_signed(r.manifest, r.signature)
      serve(r)

      assert :ok = perform_job(Mirror, %{"image_id" => image.id})
      image = Repo.reload!(image)
      assert image.mirror_state == "ready" and image.mirrored_at
      assert File.read!(image.kernel_path) == r.kernel
      assert File.read!(image.rootfs_path) == r.rootfs
      assert String.starts_with?(image.kernel_path, store)
    end

    test "a file that doesn't match its manifest fails the mirror and is removed",
         %{key: key, store: store} do
      r = release(key)
      {:ok, image} = Images.register_signed(r.manifest, r.signature)
      serve(%{r | rootfs: r.rootfs <> "x"})

      assert {:error, _} = perform_job(Mirror, %{"image_id" => image.id})
      image = Repo.reload!(image)
      assert image.mirror_state == "failed"
      assert image.mirror_error =~ "rootfs"
      assert Path.wildcard(Path.join(store, "**/*.zst*")) == []
    end

    test "files beside a bundled manifest are used where they are, once checked",
         %{key: key, dir: dir} do
      bundle = Path.join(dir, "bundle")
      r = release(key, dir: bundle)
      Images.register_bundle(bundle)
      image = Repo.get_by!(Image, version: r.version)

      Req.Test.stub(Mirror, fn _ -> raise "no download expected" end)
      assert :ok = perform_job(Mirror, %{"image_id" => image.id})
      image = Repo.reload!(image)
      assert image.mirror_state == "ready"
      assert image.rootfs_path == Path.join(bundle, r.prefix <> ".rootfs.ext4.zst")
    end
  end

  defp register(key, version) do
    r = release(key, version: version)
    Images.register_signed(r.manifest, r.signature)
  end

  defp mirrored(image),
    do:
      Repo.update!(
        Ecto.Changeset.change(image, mirror_state: "ready", kernel_path: "k", rootfs_path: "r")
      )

  # The release's files, from GitHub's download URLs.
  defp serve(r) do
    Req.Test.stub(Mirror, fn conn ->
      body =
        cond do
          String.ends_with?(conn.request_path, "/v#{r.version}/#{r.prefix}.kernel") ->
            r.kernel

          String.ends_with?(conn.request_path, "/v#{r.version}/#{r.prefix}.rootfs.ext4.zst") ->
            r.rootfs

          true ->
            nil
        end

      if body, do: Plug.Conn.send_resp(conn, 200, body), else: Plug.Conn.send_resp(conn, 404, "")
    end)
  end
end
