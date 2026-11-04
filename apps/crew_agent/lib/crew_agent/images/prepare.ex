defmodule CrewAgent.Images.Prepare do
  @moduledoc """
  `image.prepare` on a real driver (§13.1):

  1. **Verify first:** the manifest's signature against the release key
     (`CREW_RELEASE_PUBLIC_KEY`; no key, no prepare), then that the
     manifest agrees with the command: version, arch, and the kernel's and
     compressed rootfs's SHA-256 and size.
  2. **Room:** the images directory's filesystem must hold the kernel, the
     compressed rootfs and the rootfs it decompresses to, plus 1 GiB.
  3. **Download** both into `images/.<id>.tmp/` (`CrewAgent.Images.Download`).
  4. **Verify** them against the manifest, and **convert:** decompress the
     rootfs (streamed: it's gigabytes), checking what comes out against
     `rootfs_ext4_sha256` and `rootfs_ext4_size`.
  5. **Lay out** `kernel`, `rootfs.ext4`, `manifest.json` (the signed
     bytes) and `manifest.sig`, all 0444, then `ready`, and rename the
     directory into place, so a half-prepared image is never `ready?`.

  A failure removes the temporary directory and reports `failed`. A
  prepare that's killed (`op.cancel`, an agent restart) leaves its parts,
  which the next prepare of the image resumes.

  `image.state` goes out on each change of state and while working: at
  most every `:progress_ms` (2 s) as the progress moves, and every
  `:heartbeat_ms` (30 s) when it doesn't, well inside the control plane's
  30 minutes before it sends the prepare again.
  """

  import Bitwise

  alias CrewAgent.{Config, HostMetrics, Identity, Images, SafeFS}
  alias CrewAgent.Images.Download
  alias CrewProtocol.Auth

  @margin 1 <<< 30
  @read_chunk 1_048_576
  @parts ["kernel.part", "rootfs.ext4.zst.part"]
  @progress {__MODULE__, :progress}

  # The window `zstd --long=27` compresses with, and zstd's default limit.
  @window_log_max 27

  @spec run(Config.t(), map(), keyword()) :: :ok | {:error, String.t(), String.t()}
  def run(config, image, opts \\ []) do
    Process.put(@progress, %{
      id: image.id,
      every: Keyword.get(opts, :progress_ms, 2_000),
      heartbeat: Keyword.get(opts, :heartbeat_ms, 30_000),
      at: nil,
      state: nil,
      pct: nil
    })

    tmp = Images.tmp_dir(config, image.id)

    case safely(fn -> steps(config, image, tmp, opts) end) do
      :ok ->
        Images.report(image.id, "ready", 100, nil)
        :ok

      {:error, code, message} ->
        File.rm_rf(tmp)
        Images.report(image.id, "failed", 0, message)
        {:error, code, message}
    end
  end

  defp steps(config, image, tmp, opts) do
    with {:ok, key} <- release_key(config),
         {:ok, bytes} <- verify_signature(image, key),
         {:ok, manifest} <- parse(bytes),
         :ok <- agree(manifest, image),
         :ok <- check_space(config, image, manifest, opts),
         :ok <- clear(tmp),
         {:ok, kernel_sha} <- download(config, image, :kernel, tmp, opts),
         {:ok, rootfs_sha} <- download(config, image, :rootfs, tmp, opts),
         :ok <- check_downloads(image, kernel_sha, rootfs_sha),
         :ok <- convert(image, manifest, tmp) do
      lay_out(config, image, bytes, tmp)
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, "image_failed", "preparing the image failed: #{Exception.message(e)}"}
  end

  # -- 1. verify first ---------------------------------------------------------

  defp release_key(%Config{release_public_key: key}) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp release_key(_config),
    do:
      {:error, "no_release_key",
       "no release key is configured (CREW_RELEASE_PUBLIC_KEY), so the image's signature can't be checked"}

  defp verify_signature(image, key) do
    bytes = Base.decode64!(image.manifest)

    case Auth.verify_manifest(bytes, image.signature, key) do
      :ok ->
        {:ok, bytes}

      {:error, :bad_signature} ->
        {:error, "bad_signature",
         "the image manifest's signature doesn't verify against the release key"}
    end
  end

  @shas ~w(kernel_sha256 rootfs_sha256 rootfs_ext4_sha256)
  @sizes ~w(kernel_size rootfs_size rootfs_ext4_size)

  defp parse(bytes) do
    with {:ok, %{} = m} <- Jason.decode(bytes),
         nil <- Enum.find(~w(version arch), &(not is_binary(m[&1]))),
         nil <- Enum.find(@shas, &(not (is_binary(m[&1]) and m[&1] =~ ~r/\A[0-9a-f]{64}\z/))),
         nil <- Enum.find(@sizes, &(not (is_integer(m[&1]) and m[&1] >= 0))) do
      {:ok, m}
    else
      field when is_binary(field) ->
        {:error, "bad_manifest", "the image manifest has no valid #{field}"}

      _ ->
        {:error, "bad_manifest", "the image manifest isn't a JSON object"}
    end
  end

  defp agree(m, image) do
    pairs = [
      {"version", image.version},
      {"arch", image.arch},
      {"kernel_sha256", image.kernel.sha256},
      {"kernel_size", image.kernel.size},
      {"rootfs_sha256", image.rootfs.sha256},
      {"rootfs_size", image.rootfs.size}
    ]

    case Enum.find(pairs, fn {field, value} -> m[field] != value end) do
      nil ->
        :ok

      {field, value} ->
        {:error, "manifest_mismatch",
         "the manifest's #{field} (#{inspect(m[field])}) isn't the command's (#{inspect(value)})"}
    end
  end

  # -- 2. room -----------------------------------------------------------------

  defp check_space(config, image, m, opts) do
    dir = Config.images_dir(config)
    File.mkdir_p!(dir)
    need = image.kernel.size + image.rootfs.size + m["rootfs_ext4_size"] + @margin

    case Keyword.get(opts, :free_bytes, &free_bytes/1).(dir) do
      {:ok, free} when free >= need ->
        :ok

      {:ok, free} ->
        {:error, "no_space",
         "the image needs #{mib(need)} MiB free in #{dir} (with 1 GiB to spare), and there's #{mib(free)} MiB"}

      {:error, reason} ->
        {:error, "no_space", "couldn't find the free space in #{dir}: #{reason}"}
    end
  end

  @doc "Free bytes on the filesystem holding `dir`, from `df -Pk`."
  @spec free_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def free_bytes(dir) do
    case System.cmd("df", ["-Pk", dir], stderr_to_stdout: true) do
      {out, 0} ->
        {_total, free_mib} = HostMetrics.parse_df(out)
        {:ok, free_mib * 1_048_576}

      {out, _} ->
        {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp mib(bytes), do: div(bytes, 1_048_576)

  # -- 3. download -------------------------------------------------------------

  # A part left by a killed prepare is kept, to resume; anything else
  # there (a half-converted rootfs) goes.
  defp clear(tmp) do
    File.mkdir_p!(tmp)
    for f <- File.ls!(tmp), f not in @parts, do: File.rm_rf!(Path.join(tmp, f))
    :ok
  end

  defp download(config, image, which, tmp, opts) do
    ref = Map.fetch!(image, which)
    before = if which == :rootfs, do: image.kernel.size, else: 0
    total = image.kernel.size + image.rootfs.size
    tick("downloading", pct(before, total))

    download_opts =
      [
        on_bytes: &tick("downloading", pct(before + &1, total)),
        on_retry: fn -> tick("downloading", pct(before, total)) end,
        sign: signer(config)
      ] ++ Keyword.take(opts, [:attempts, :retry_delay_ms, :req_options])

    case Download.fetch(ref.url, part(tmp, which), ref.size, download_opts) do
      {:ok, sha} ->
        {:ok, sha}

      {:error, reason} ->
        {:error, "download_failed", "downloading the #{name(which)} failed: #{reason}"}
    end
  end

  defp part(tmp, :kernel), do: Path.join(tmp, "kernel.part")
  defp part(tmp, :rootfs), do: Path.join(tmp, "rootfs.ext4.zst.part")

  defp name(:kernel), do: "kernel"
  defp name(:rootfs), do: "root filesystem"

  # Downloads from the control plane carry the agent's signed headers, as
  # its socket does; other hosts get none.
  defp signer(%Config{url: url} = config) when is_binary(url) and url != "" do
    case Identity.load(Config.agent_dir(config)) do
      {:ok, identity} ->
        home = origin(URI.parse(url))

        fn uri ->
          if origin(uri) == home,
            do: Enum.to_list(Auth.connect_headers(identity.agent_id, identity.private_key)),
            else: []
        end

      _ ->
        nil
    end
  end

  defp signer(_config), do: nil

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    {if(scheme in ["wss", "https"], do: "https", else: "http"), host, port}
  end

  # -- 4. verify and convert ---------------------------------------------------

  defp check_downloads(image, kernel_sha, rootfs_sha) do
    tick("verifying", 0)

    cond do
      kernel_sha != image.kernel.sha256 ->
        {:error, "checksum_mismatch",
         "the kernel's SHA-256 is #{kernel_sha}, not the manifest's #{image.kernel.sha256}"}

      rootfs_sha != image.rootfs.sha256 ->
        {:error, "checksum_mismatch",
         "the root filesystem's SHA-256 is #{rootfs_sha}, not the manifest's #{image.rootfs.sha256}"}

      true ->
        :ok
    end
  end

  defp convert(image, m, tmp) do
    tick("converting", 0)
    src = part(tmp, :rootfs)
    dest = Path.join(tmp, "rootfs.ext4")
    {:ok, zstd} = :zstd.context(:decompress, %{windowLogMax: @window_log_max})
    {:ok, input} = :file.open(src, [:read, :raw, :binary])
    {:ok, output} = :file.open(dest, [:write, :raw, :binary])
    st = %{read: 0, total: image.rootfs.size, written: 0, limit: m["rootfs_ext4_size"], hash: nil}

    result =
      try do
        with {:ok, st} <- pump(zstd, input, output, %{st | hash: :crypto.hash_init(:sha256)}),
             :ok <- sync(output, "rootfs.ext4"),
             do: {:ok, st}
      catch
        :error, {:zstd_error, reason} ->
          {:error, "convert_failed", "decompressing the root filesystem failed: #{reason}"}
      after
        :file.close(input)
        :file.close(output)
        :zstd.close(zstd)
      end

    with {:ok, st} <- result do
      File.rm!(src)
      check_ext4(st, m)
    end
  end

  defp sync(fd, name) do
    case :file.sync(fd) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "image_failed", "syncing #{name} failed: #{:file.format_error(reason)}"}
    end
  end

  defp pump(zstd, input, output, st) do
    case :file.read(input, @read_chunk) do
      {:ok, data} ->
        with {:ok, st} <- feed(zstd, data, output, st) do
          st = %{st | read: st.read + byte_size(data)}
          tick("converting", pct(st.read, st.total))
          pump(zstd, input, output, st)
        end

      :eof ->
        {:done, out} = :zstd.finish(zstd, <<>>)
        put(output, IO.iodata_to_binary(out), st)

      {:error, reason} ->
        {:error, "image_failed",
         "reading the root filesystem failed: #{:file.format_error(reason)}"}
    end
  end

  defp feed(zstd, data, output, st) do
    case :zstd.stream(zstd, data) do
      {:continue, rest, out} ->
        with {:ok, st} <- put(output, out, st), do: feed(zstd, rest, output, st)

      {:continue, out} ->
        put(output, out, st)
    end
  end

  defp put(_output, <<>>, st), do: {:ok, st}

  defp put(output, out, st) do
    written = st.written + byte_size(out)

    if written > st.limit do
      {:error, "checksum_mismatch",
       "rootfs.ext4 decompresses to more than the manifest's #{st.limit} bytes"}
    else
      case :file.write(output, out) do
        :ok ->
          {:ok, %{st | written: written, hash: :crypto.hash_update(st.hash, out)}}

        {:error, reason} ->
          {:error, "image_failed", "writing rootfs.ext4 failed: #{:file.format_error(reason)}"}
      end
    end
  end

  defp check_ext4(st, m) do
    sha = st.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    if st.written == m["rootfs_ext4_size"] and sha == m["rootfs_ext4_sha256"],
      do: :ok,
      else:
        {:error, "checksum_mismatch",
         "rootfs.ext4 decompressed to #{st.written} bytes with SHA-256 #{sha}, not the manifest's " <>
           "#{m["rootfs_ext4_size"]} bytes with #{m["rootfs_ext4_sha256"]}"}
  end

  # -- 5. lay out --------------------------------------------------------------

  defp lay_out(config, image, manifest, tmp) do
    final = Images.dir(config, image.id)

    with :ok <- File.rename(part(tmp, :kernel), Path.join(tmp, "kernel")),
         :ok <- File.chmod(Path.join(tmp, "kernel"), 0o444),
         :ok <- File.chmod(Path.join(tmp, "rootfs.ext4"), 0o444),
         :ok <- SafeFS.write_atomic(Path.join(tmp, "manifest.json"), manifest, 0o444),
         :ok <- SafeFS.write_atomic(Path.join(tmp, "manifest.sig"), image.signature, 0o444),
         :ok <- SafeFS.write_atomic(Path.join(tmp, "ready"), "", 0o444),
         {:ok, _} <- File.rm_rf(final),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, reason, path} ->
        {:error, "image_failed", "removing #{path} failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "image_failed", "laying out the image failed: #{inspect(reason)}"}
    end
  end

  # -- progress ----------------------------------------------------------------

  defp pct(_done, 0), do: 100
  defp pct(done, total), do: min(div(done * 100, total), 100)

  defp tick(state, pct) do
    p = Process.get(@progress)
    now = System.monotonic_time(:millisecond)
    since = p.at && now - p.at

    if p.at == nil or state != p.state or (pct != p.pct and since >= p.every) or
         since >= p.heartbeat do
      Images.report(p.id, state, pct, nil)
      Process.put(@progress, %{p | at: now, state: state, pct: pct})
    end

    :ok
  end
end
