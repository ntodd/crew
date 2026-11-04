defmodule CrewImage.Artifacts do
  @moduledoc """
  A guest image release's files, per arch (docs/crew_spec.md §13.1):

      crew-guest-<version>-<arch>.manifest.json
      crew-guest-<version>-<arch>.manifest.sig     base64 ed25519, no newline
      crew-guest-<version>-<arch>.kernel           Image (arm64) or vmlinux (x64)
      crew-guest-<version>-<arch>.rootfs.ext4.zst

  `write/2` lays them out (the compressed rootfs is made beforehand),
  `sign/2` adds the signature and `verify/3` checks a set the way a box
  will: the signature over the manifest's exact bytes, then every file
  against the manifest.
  """

  alias CrewImage.{Keys, Manifest}

  @doc """
  Writes the manifest and copies the kernel into `dir`, under the release
  names. Takes `CrewImage.Manifest.from_files/1`'s options. The compressed
  rootfs is moved in unless it's there already.
  """
  def write(dir, opts) do
    names = Manifest.names(Keyword.fetch!(opts, :version), Keyword.fetch!(opts, :arch))
    paths = paths(dir, names)
    File.mkdir_p!(dir)

    with :ok <- place(opts[:kernel], paths.kernel, :copy),
         :ok <- place(opts[:rootfs_zst], paths.rootfs, :move),
         {:ok, bytes} <-
           Manifest.from_files(
             Keyword.merge(opts, kernel: paths.kernel, rootfs_zst: paths.rootfs)
           ),
         :ok <- File.write(paths.manifest, bytes) do
      File.rm(paths.signature)
      {:ok, paths}
    end
  end

  @doc "Signs the manifest at `manifest` with `private`, writing the .sig beside it."
  def sign(manifest, private) do
    with {:ok, bytes} <- File.read(manifest),
         {:ok, _} <- Manifest.parse(bytes) do
      File.write(signature_path(manifest), Keys.sign(bytes, private))
    end
  end

  @doc """
  Verifies the release whose manifest is at `manifest` against `public`.
  Options: `release: true` refuses the test key; `rootfs_ext4:` also
  checks an uncompressed rootfs against the manifest.

  Returns `:ok` or `{:error, problems}`.
  """
  def verify(manifest, public, opts \\ []) do
    with :ok <- release_key(public, opts),
         {:ok, bytes} <- read(manifest),
         {:ok, sig} <- read(signature_path(manifest)),
         :ok <- signature(bytes, String.trim(sig), public),
         {:ok, m} <- parse(bytes),
         {:ok, names} <- name(manifest, m) do
      dir = Path.dirname(manifest)

      files =
        [{"kernel", Path.join(dir, names.kernel)}, {"rootfs", Path.join(dir, names.rootfs)}] ++
          if ext4 = opts[:rootfs_ext4], do: [{"rootfs_ext4", ext4}], else: []

      case Enum.flat_map(files, fn {field, path} -> check_file(m, field, path) end) do
        [] -> :ok
        problems -> {:error, problems}
      end
    end
  end

  def signature_path(manifest),
    do: String.replace_suffix(manifest, ".manifest.json", ".manifest.sig")

  defp paths(dir, names), do: Map.new(names, fn {k, name} -> {k, Path.join(dir, name)} end)

  defp place(nil, _dest, _how), do: {:error, {:missing, nil}}

  defp place(src, dest, how) do
    cond do
      Path.expand(src) == Path.expand(dest) -> :ok
      not File.regular?(src) -> {:error, {:missing, src}}
      how == :copy -> File.cp(src, dest)
      how == :move -> File.rename(src, dest)
    end
  end

  defp release_key(public, opts) do
    if opts[:release] && Keys.test_key?(public),
      do: {:error, [:test_key_for_release]},
      else: :ok
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, [{:missing, path}]}
    end
  end

  defp signature(bytes, sig, public) do
    case Keys.verify(bytes, sig, public) do
      :ok -> :ok
      {:error, reason} -> {:error, [reason]}
    end
  end

  defp parse(bytes) do
    case Manifest.parse(bytes) do
      {:ok, m} -> {:ok, m}
      {:error, reason} -> {:error, [{:manifest, reason}]}
    end
  end

  defp name(manifest, m) do
    names = Manifest.names(m["version"], m["arch"])

    if Path.basename(manifest) == names.manifest,
      do: {:ok, names},
      else: {:error, [{:name, "#{Path.basename(manifest)} holds #{names.manifest}"}]}
  end

  defp check_file(m, field, path) do
    want = %{sha256: m[field <> "_sha256"], size: m[field <> "_size"]}

    case Manifest.digest(path) do
      {:ok, ^want} -> []
      {:ok, got} -> [{:mismatch, field, %{path: path, want: want, got: got}}]
      {:error, {:missing, _}} -> [{:missing, path}]
    end
  end
end
