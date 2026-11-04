# A small guest image release for the browser tests (§13.1): a fake
# kernel and root filesystem, the manifest CI would write, signed with
# the development test key, laid out as the control plane's image
# carries a release. Run from apps/crew:
#
#   mix run --no-start ../../e2e/make_release.exs <dir> [version]
[dir | rest] = System.argv()
version = List.first(rest) || "0.9.0"
root = Path.expand("..", __DIR__)

seed =
  Path.join(root, "images/guest/keys/test-signing.key")
  |> File.read!()
  |> String.split("\n")
  |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
  |> Enum.join()
  |> String.trim()
  |> Base.decode64!()

sha = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))

for arch <- ["arm64", "x64"] do
  kernel = "e2e kernel #{version} #{arch}\n"
  ext4 = :binary.copy("e2e rootfs #{version} #{arch}\n", 4096)
  zst = IO.iodata_to_binary(:zstd.compress(ext4))
  prefix = Path.join(dir, "crew-guest-#{version}-#{arch}")

  manifest =
    Jason.encode!(%{
      "version" => version,
      "arch" => arch,
      "kernel_sha256" => sha.(kernel),
      "kernel_size" => byte_size(kernel),
      "rootfs_sha256" => sha.(zst),
      "rootfs_size" => byte_size(zst),
      "rootfs_ext4_sha256" => sha.(ext4),
      "rootfs_ext4_size" => byte_size(ext4),
      "kernel_version" => "6.18.60-crew",
      "runner_version" => "2.338.2",
      "docker_version" => "29.9.2",
      "packages_lock_sha256" => sha.("e2e"),
      "disable_update" => true
    })

  File.mkdir_p!(dir)
  File.write!(prefix <> ".kernel", kernel)
  File.write!(prefix <> ".rootfs.ext4.zst", zst)
  File.write!(prefix <> ".manifest.json", manifest)
  File.write!(prefix <> ".manifest.sig", CrewProtocol.Auth.sign_manifest(manifest, seed))
end
