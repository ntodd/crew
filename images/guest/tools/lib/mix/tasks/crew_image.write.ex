defmodule Mix.Tasks.CrewImage.Write do
  @shortdoc "Writes a guest image's release files and manifest"
  @moduledoc """
  Lays out a guest image's release files and writes its manifest
  (docs/crew_spec.md §13.1; see `CrewImage.Manifest`).

      mix crew_image.write <dir> --version 0.1.0 --arch arm64 \\
        --kernel out/arm64/kernel/Image --kernel-release out/arm64/kernel/release \\
        --rootfs out/arm64/rootfs.ext4 --rootfs-zst <dir>/crew-guest-…rootfs.ext4.zst \\
        --lock images/guest/packages.lock --versions images/guest/versions.env

  Fails if the compressed rootfs is over 2 GiB.
  """
  use Mix.Task

  @switches [
    version: :string,
    arch: :string,
    kernel: :string,
    kernel_release: :string,
    rootfs: :string,
    rootfs_zst: :string,
    lock: :string,
    versions: :string
  ]

  @impl true
  def run(args) do
    {opts, [dir]} = OptionParser.parse!(args, strict: @switches)

    for key <- Keyword.keys(@switches),
        not Keyword.has_key?(opts, key),
        do:
          Mix.raise("crew_image.write: --#{String.replace(to_string(key), "_", "-")} is required")

    case CrewImage.Artifacts.write(dir, opts) do
      {:ok, paths} ->
        m = paths.manifest |> File.read!() |> Jason.decode!()
        Mix.shell().info("wrote #{paths.manifest}")

        Mix.shell().info(
          "  kernel #{m["kernel_size"]} bytes, rootfs #{m["rootfs_size"]} bytes compressed " <>
            "(#{m["rootfs_ext4_size"]} as ext4), runner #{m["runner_version"]}, docker #{m["docker_version"]}"
        )

      {:error, reason} ->
        Mix.raise("crew_image.write: #{inspect(reason)}")
    end
  end
end
