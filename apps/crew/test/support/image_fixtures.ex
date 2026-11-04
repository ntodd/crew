defmodule Crew.ImageFixtures do
  @moduledoc """
  Signed guest image releases for tests (§13.1): a kernel, a compressed
  root filesystem and a manifest signed with a key made for the test.
  """

  def keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: pub, private: priv}
  end

  @doc "Trusts `key` as the release key for the rest of the test."
  def trust(%{public: pub}) do
    previous = Application.get_env(:crew, :release_public_key)
    Application.put_env(:crew, :release_public_key, Base.encode64(pub))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:crew, :release_public_key, previous)
    end)
  end

  @doc """
  A release's files as CI names them, in `dir` when given:
  `crew-guest-<version>-<arch>.{kernel,rootfs.ext4.zst,manifest.json,manifest.sig}`.
  """
  def release(key, attrs \\ []) do
    version = Keyword.get(attrs, :version, "1.2.0")
    arch = Keyword.get(attrs, :arch, "arm64")
    kernel = Keyword.get(attrs, :kernel, "kernel-" <> :crypto.strong_rand_bytes(64))
    ext4 = Keyword.get(attrs, :ext4, "ext4-" <> :crypto.strong_rand_bytes(256))
    zst = IO.iodata_to_binary(:zstd.compress(ext4))

    manifest =
      Jason.encode!(%{
        "version" => version,
        "arch" => arch,
        "kernel_sha256" => sha(kernel),
        "kernel_size" => byte_size(kernel),
        "rootfs_sha256" => sha(zst),
        "rootfs_size" => byte_size(zst),
        "rootfs_ext4_sha256" => sha(ext4),
        "rootfs_ext4_size" => byte_size(ext4),
        "kernel_version" => "6.18.60-crew",
        "runner_version" => Keyword.get(attrs, :runner_version, "2.338.2"),
        "docker_version" => "29.9.2",
        "packages_lock_sha256" => sha("lock"),
        "disable_update" => true
      })

    release = %{
      version: version,
      arch: arch,
      prefix: "crew-guest-#{version}-#{arch}",
      kernel: kernel,
      rootfs: zst,
      manifest: manifest,
      signature: CrewProtocol.Auth.sign_manifest(manifest, key.private)
    }

    if dir = attrs[:dir], do: write(release, dir, Keyword.get(attrs, :files, true))
    release
  end

  def write(release, dir, files? \\ true) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, release.prefix <> ".manifest.json"), release.manifest)
    File.write!(Path.join(dir, release.prefix <> ".manifest.sig"), release.signature)

    if files? do
      File.write!(Path.join(dir, release.prefix <> ".kernel"), release.kernel)
      File.write!(Path.join(dir, release.prefix <> ".rootfs.ext4.zst"), release.rootfs)
    end

    release
  end

  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
