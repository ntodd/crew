ExUnit.start()

defmodule CrewImage.TestHelpers do
  @moduledoc false

  def write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @lock """
  # a comment
  base ubuntu:24.04@sha256:00
  snapshot 20261102T000000Z
  arm64 containerd.io 2.4.2-3~ubuntu.24.04~noble
  arm64 docker-ce 5:29.9.2-1~ubuntu.24.04~noble
  x64 docker-ce 5:29.9.1-1~ubuntu.24.04~noble
  arm64 zlib1g 1:1.3.dfsg-3.1ubuntu2.1
  """

  @versions """
  # comment
  KERNEL_VERSION=6.18.60
  RUNNER_VERSION=2.338.2
  """

  def lock_text, do: @lock

  @doc "A directory with what the artifacts step starts from."
  def build_dir!(dir, opts \\ []) do
    %{
      kernel: write!(dir, "kernel/Image", Keyword.get(opts, :kernel, "kernel bytes")),
      release: write!(dir, "kernel/release", "6.18.60-crew\n"),
      rootfs: write!(dir, "rootfs.ext4", "ext4 bytes"),
      rootfs_zst: write!(dir, "rootfs.ext4.zst", "zst bytes"),
      lock: write!(dir, "packages.lock", Keyword.get(opts, :lock, @lock)),
      versions: write!(dir, "versions.env", @versions)
    }
  end

  def manifest_opts(files, overrides \\ []) do
    Keyword.merge(
      [
        version: "0.1.0",
        arch: "arm64",
        kernel: files.kernel,
        kernel_release: files.release,
        rootfs: files.rootfs,
        rootfs_zst: files.rootfs_zst,
        lock: files.lock,
        versions: files.versions
      ],
      overrides
    )
  end
end
