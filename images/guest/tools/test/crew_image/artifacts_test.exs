defmodule CrewImage.ArtifactsTest do
  use ExUnit.Case, async: true

  import CrewImage.TestHelpers

  alias CrewImage.{Artifacts, Keys, Manifest}
  alias CrewProtocol.Auth

  @moduletag :tmp_dir

  # A release directory as the artifacts step leaves it, signed with a
  # fresh key.
  defp signed_release(dir) do
    files = build_dir!(Path.join(dir, "build"))
    release = Path.join(dir, "release")
    {public, private} = Auth.generate_keypair()

    {:ok, paths} =
      Artifacts.write(release, manifest_opts(files))

    :ok = Artifacts.sign(paths.manifest, private)
    %{paths: paths, public: public, private: private, files: files}
  end

  test "write/3 lays out crew-guest-<version>-<arch>.* and sign/2 adds the signature",
       %{tmp_dir: dir} do
    %{paths: paths} = signed_release(dir)

    assert Path.basename(paths.manifest) == "crew-guest-0.1.0-arm64.manifest.json"
    assert File.read!(paths.kernel) == "kernel bytes"
    assert File.read!(paths.rootfs) == "zst bytes"
    assert {:ok, %{"arch" => "arm64"}} = paths.manifest |> File.read!() |> Manifest.parse()

    sig = File.read!(paths.signature)
    assert sig == String.trim(sig), "the signature file is the base64 alone, no newline"
    assert {:ok, <<_::binary-size(64)>>} = Base.decode64(sig)
  end

  test "verify/3 accepts a signed release, and checks the ext4 when given", %{tmp_dir: dir} do
    %{paths: paths, public: public, files: files} = signed_release(dir)

    assert Artifacts.verify(paths.manifest, public) == :ok
    assert Artifacts.verify(paths.manifest, public, rootfs_ext4: files.rootfs) == :ok

    File.write!(files.rootfs, "other ext4")

    assert {:error, [{:mismatch, "rootfs_ext4", _}]} =
             Artifacts.verify(paths.manifest, public, rootfs_ext4: files.rootfs)
  end

  test "verify/3 refuses another key's signature, or none", %{tmp_dir: dir} do
    %{paths: paths} = signed_release(dir)
    {other, _} = Auth.generate_keypair()

    assert {:error, [:bad_signature]} = Artifacts.verify(paths.manifest, other)

    File.rm!(paths.signature)
    assert {:error, [{:missing, sig}]} = Artifacts.verify(paths.manifest, other)
    assert sig =~ ".manifest.sig"
  end

  test "verify/3 refuses artifacts that don't match the manifest", %{tmp_dir: dir} do
    %{paths: paths, public: public} = signed_release(dir)

    File.write!(paths.kernel, "kernel bytez")
    File.write!(paths.rootfs, "zst")

    assert {:error, problems} = Artifacts.verify(paths.manifest, public)
    assert {:mismatch, "kernel", _} = List.keyfind(problems, "kernel", 1)
    assert {:mismatch, "rootfs", _} = List.keyfind(problems, "rootfs", 1)
  end

  test "verify/3 refuses a manifest whose file name doesn't match it", %{tmp_dir: dir} do
    %{paths: paths, public: public} = signed_release(dir)
    renamed = String.replace(paths.manifest, "0.1.0", "0.2.0")
    File.rename!(paths.manifest, renamed)
    File.rename!(paths.signature, String.replace(paths.signature, "0.1.0", "0.2.0"))

    assert {:error, [{:name, _}]} = Artifacts.verify(renamed, public)
  end

  test "verify/3 with release: true refuses a test-key signature", %{tmp_dir: dir} do
    files = build_dir!(Path.join(dir, "build"))
    release = Path.join(dir, "release")

    {:ok, paths} =
      Artifacts.write(release, manifest_opts(files))

    {:ok, test_key} = Keys.load_private(file: Keys.test_key_path())
    :ok = Artifacts.sign(paths.manifest, test_key)

    assert Artifacts.verify(paths.manifest, Keys.test_public_key()) == :ok

    assert {:error, [:test_key_for_release]} =
             Artifacts.verify(paths.manifest, Keys.test_public_key(), release: true)
  end
end
