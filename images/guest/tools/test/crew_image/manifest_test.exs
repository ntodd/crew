defmodule CrewImage.ManifestTest do
  use ExUnit.Case, async: true

  import CrewImage.TestHelpers

  alias CrewImage.Manifest

  @fields ~w(version arch kernel_sha256 kernel_size rootfs_sha256 rootfs_size
             rootfs_ext4_sha256 rootfs_ext4_size kernel_version runner_version
             docker_version packages_lock_sha256 disable_update)

  @moduletag :tmp_dir

  test "describes the artifacts, its fields always in the same order", %{tmp_dir: dir} do
    files = build_dir!(dir)
    assert {:ok, bytes} = Manifest.from_files(manifest_opts(files))

    m = Jason.decode!(bytes, objects: :ordered_objects)
    assert Enum.map(m.values, &elem(&1, 0)) == @fields
    assert String.ends_with?(bytes, "}\n")

    m = Jason.decode!(bytes)
    assert m["version"] == "0.1.0"
    assert m["arch"] == "arm64"
    assert m["kernel_sha256"] == sha256("kernel bytes")
    assert m["kernel_size"] == byte_size("kernel bytes")
    assert m["kernel_version"] == "6.18.60-crew"
    assert m["runner_version"] == "2.338.2"
    assert m["docker_version"] == "29.9.2"
    assert m["packages_lock_sha256"] == sha256(lock_text())
    assert m["disable_update"] == true
  end

  test "rootfs_* is the download (.zst), rootfs_ext4_* what it decompresses to",
       %{tmp_dir: dir} do
    files = build_dir!(dir)
    {:ok, bytes} = Manifest.from_files(manifest_opts(files))
    m = Jason.decode!(bytes)

    assert m["rootfs_sha256"] == sha256("zst bytes")
    assert m["rootfs_size"] == byte_size("zst bytes")
    assert m["rootfs_ext4_sha256"] == sha256("ext4 bytes")
    assert m["rootfs_ext4_size"] == byte_size("ext4 bytes")
  end

  test "the same inputs give the same bytes", %{tmp_dir: dir} do
    files = build_dir!(dir)
    assert Manifest.from_files(manifest_opts(files)) == Manifest.from_files(manifest_opts(files))
  end

  test "docker_version is the arch's docker-ce from the lock, without epoch or revision" do
    assert Manifest.docker_version(lock_text(), "arm64") == {:ok, "29.9.2"}
    assert Manifest.docker_version(lock_text(), "x64") == {:ok, "29.9.1"}

    assert Manifest.docker_version("arm64 zlib1g 1\n", "arm64") ==
             {:error, {:not_in_lock, "docker-ce"}}
  end

  test "refuses what the control plane and agent wouldn't take", %{tmp_dir: dir} do
    files = build_dir!(dir)

    assert {:error, {:bad_version, "v0.1.0"}} =
             Manifest.from_files(manifest_opts(files, version: "v0.1.0"))

    assert {:error, {:bad_version, "0.1.0+build"}} =
             Manifest.from_files(manifest_opts(files, version: "0.1.0+build"))

    assert {:error, {:bad_arch, "aarch64"}} =
             Manifest.from_files(manifest_opts(files, arch: "aarch64"))

    assert {:ok, _} = Manifest.from_files(manifest_opts(files, version: "0.1.0-dev.3"))
  end

  test "a missing file is an error, not a crash", %{tmp_dir: dir} do
    files = build_dir!(dir)

    assert {:error, {:missing, path}} =
             Manifest.from_files(manifest_opts(files, rootfs_zst: Path.join(dir, "nope.zst")))

    assert path =~ "nope.zst"
  end

  test "the compressed rootfs must fit a GitHub release asset (under 2 GiB)" do
    assert Manifest.max_rootfs_bytes() == 2 * 1024 * 1024 * 1024 - 1
    assert Manifest.check_rootfs_size(Manifest.max_rootfs_bytes()) == :ok

    assert {:error, {:rootfs_too_big, _}} =
             Manifest.check_rootfs_size(Manifest.max_rootfs_bytes() + 1)
  end

  test "parse/1 reads a manifest back and checks its fields", %{tmp_dir: dir} do
    files = build_dir!(dir)
    {:ok, bytes} = Manifest.from_files(manifest_opts(files))

    assert {:ok, %{"version" => "0.1.0", "disable_update" => true}} = Manifest.parse(bytes)

    tampered = String.replace(bytes, ~s("disable_update": true), ~s("disable_update": false))
    assert {:error, :update_not_disabled} = Manifest.parse(tampered)

    assert {:error, {:missing_field, "kernel_sha256"}} =
             bytes
             |> Jason.decode!()
             |> Map.delete("kernel_sha256")
             |> Jason.encode!()
             |> Manifest.parse()
  end

  test "file names follow crew-guest-<version>-<arch>" do
    assert Manifest.names("0.1.0", "arm64") == %{
             manifest: "crew-guest-0.1.0-arm64.manifest.json",
             signature: "crew-guest-0.1.0-arm64.manifest.sig",
             kernel: "crew-guest-0.1.0-arm64.kernel",
             rootfs: "crew-guest-0.1.0-arm64.rootfs.ext4.zst"
           }
  end
end
