defmodule CrewImage.Manifest do
  @moduledoc """
  A guest image's manifest, `crew-guest-<version>-<arch>.manifest.json`
  (docs/crew_spec.md §13.1). Its exact bytes are what's signed.

  Field names are the control plane's (`Crew.Images.Image`): `version`,
  `arch`, `kernel_sha256`, `kernel_size`, `rootfs_sha256`, `rootfs_size`,
  `runner_version`, `docker_version`. Then:

  - `rootfs_sha256` and `rootfs_size` describe what a box downloads, the
    `.rootfs.ext4.zst`: they're what `image.prepare`'s `rootfs` file ref
    carries and what the agent checks the download against.
    `rootfs_ext4_sha256` and `rootfs_ext4_size` describe the `rootfs.ext4`
    it decompresses to, so the agent can check for room first and verify
    the result.
  - `kernel_version` is the kernel's release (`uname -r`).
  - `packages_lock_sha256` is the SHA-256 of `packages.lock`.
  - `disable_update` is always `true`: the runner never updates itself.

  `arch` is `arm64` or `x64`, the protocol's names, and `version` must be
  a version the protocol takes (`1.2.3` or `1.2.3-pre`).
  """

  @fields ~w(version arch kernel_sha256 kernel_size rootfs_sha256 rootfs_size
             rootfs_ext4_sha256 rootfs_ext4_size kernel_version runner_version
             docker_version packages_lock_sha256 disable_update)

  # CrewProtocol.Schema's :version.
  @version ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z.]{1,32})?\z/
  @arches ~w(arm64 x64)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  # A GitHub release asset must be under 2 GiB.
  @max_rootfs 2 * 1024 * 1024 * 1024 - 1

  def max_rootfs_bytes, do: @max_rootfs

  @doc "The artifact file names for a version and arch."
  def names(version, arch) do
    base = "crew-guest-#{version}-#{arch}"

    %{
      manifest: base <> ".manifest.json",
      signature: base <> ".manifest.sig",
      kernel: base <> ".kernel",
      rootfs: base <> ".rootfs.ext4.zst"
    }
  end

  @doc """
  Builds the manifest's bytes from the files. Options (all required):
  `:version`, `:arch`, `:kernel`, `:kernel_release` (a file holding it),
  `:rootfs` (the ext4), `:rootfs_zst`, `:lock` (packages.lock) and
  `:versions` (versions.env, for `RUNNER_VERSION`).
  """
  @spec from_files(keyword()) :: {:ok, binary()} | {:error, term()}
  def from_files(opts) do
    version = Keyword.fetch!(opts, :version)
    arch = Keyword.fetch!(opts, :arch)

    with :ok <- check_version(version),
         :ok <- check_arch(arch),
         {:ok, kernel} <- digest(opts[:kernel]),
         {:ok, zst} <- digest(opts[:rootfs_zst]),
         :ok <- check_rootfs_size(zst.size),
         {:ok, ext4} <- digest(opts[:rootfs]),
         {:ok, release} <- read(opts[:kernel_release]),
         {:ok, lock} <- read(opts[:lock]),
         {:ok, docker} <- docker_version(lock, arch),
         {:ok, versions} <- read(opts[:versions]),
         {:ok, runner} <- env_value(versions, "RUNNER_VERSION") do
      {:ok,
       encode([
         {"version", version},
         {"arch", arch},
         {"kernel_sha256", kernel.sha256},
         {"kernel_size", kernel.size},
         {"rootfs_sha256", zst.sha256},
         {"rootfs_size", zst.size},
         {"rootfs_ext4_sha256", ext4.sha256},
         {"rootfs_ext4_size", ext4.size},
         {"kernel_version", String.trim(release)},
         {"runner_version", runner},
         {"docker_version", docker},
         {"packages_lock_sha256", sha256(lock)},
         {"disable_update", true}
       ])}
    end
  end

  @doc "Reads a manifest's bytes back, checking every field."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(bytes) do
    with {:ok, %{} = m} <- Jason.decode(bytes),
         :ok <- require_fields(m),
         :ok <- check_version(m["version"]),
         :ok <- check_arch(m["arch"]),
         :ok <- check_digests(m),
         :ok <- check_rootfs_size(m["rootfs_size"]) do
      if m["disable_update"] === true, do: {:ok, m}, else: {:error, :update_not_disabled}
    else
      {:ok, _} -> {:error, :not_an_object}
      {:error, %Jason.DecodeError{}} -> {:error, :not_json}
      error -> error
    end
  end

  @doc "Fails if the compressed rootfs wouldn't fit a GitHub release asset."
  def check_rootfs_size(size) when is_integer(size) and size >= 0 and size <= @max_rootfs,
    do: :ok

  def check_rootfs_size(size), do: {:error, {:rootfs_too_big, size}}

  @doc """
  The Docker Engine version in the lock for `arch`: docker-ce's version
  without its epoch and Debian revision (`5:29.9.2-1~ubuntu…` is `29.9.2`).
  """
  def docker_version(lock, arch) do
    lock
    |> String.split("\n")
    |> Enum.find_value({:error, {:not_in_lock, "docker-ce"}}, fn line ->
      case String.split(line) do
        [^arch, "docker-ce", v] -> {:ok, upstream_version(v)}
        _ -> nil
      end
    end)
  end

  defp upstream_version(v) do
    v
    |> String.replace(~r/\A\d+:/, "")
    |> String.replace(~r/-[^-]*\z/, "")
  end

  # Pretty, with the fields in order and a final newline, so it reads well
  # in a release and diffs well between them.
  defp encode(pairs), do: Jason.encode!(Jason.OrderedObject.new(pairs), pretty: true) <> "\n"

  defp require_fields(m) do
    case Enum.find(@fields, &(not Map.has_key?(m, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  defp check_digests(m) do
    bad =
      Enum.find(~w(kernel rootfs rootfs_ext4), fn f ->
        not (is_binary(m[f <> "_sha256"]) and Regex.match?(@sha256, m[f <> "_sha256"]) and
               is_integer(m[f <> "_size"]) and m[f <> "_size"] >= 0)
      end)

    if bad, do: {:error, {:bad_digest, bad}}, else: :ok
  end

  defp check_version(v) when is_binary(v),
    do: if(Regex.match?(@version, v), do: :ok, else: {:error, {:bad_version, v}})

  defp check_version(v), do: {:error, {:bad_version, v}}

  defp check_arch(a) when a in @arches, do: :ok
  defp check_arch(a), do: {:error, {:bad_arch, a}}

  defp env_value(text, key) do
    text
    |> String.split("\n")
    |> Enum.find_value({:error, {:not_in_versions, key}}, fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [^key, value] when value != "" -> {:ok, value}
        _ -> nil
      end
    end)
  end

  @doc "A file's SHA-256 (lowercase hex) and size, streamed."
  def digest(nil), do: {:error, {:missing, nil}}

  def digest(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        hash =
          path
          |> File.stream!(1024 * 1024)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, %{sha256: hash, size: size}}

      _ ->
        {:error, {:missing, path}}
    end
  end

  defp read(nil), do: {:error, {:missing, nil}}

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, {:missing, path}}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
