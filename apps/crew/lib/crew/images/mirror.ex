defmodule Crew.Images.Mirror do
  @moduledoc """
  The control plane's copy of an image's kernel and compressed root
  filesystem (§13.1, §20.1), which boxes download from it. Files beside
  the bundled manifest are used where they are; otherwise they come from
  the GitHub release, streamed to disk and capped at the manifest's size.
  Either way each is checked against the signed manifest before the
  image is marked ready. A failure is retried with Oban's backoff.
  """
  use Oban.Worker,
    queue: :images,
    max_attempts: 20,
    unique: [
      keys: [:image_id],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Crew.Images
  alias Crew.Images.Image

  @impl true
  def perform(%Oban.Job{args: %{"image_id" => id}}) do
    case Images.get(id) do
      %Image{mirror_state: state} = image when state != "ready" -> mirror(image)
      _ -> :ok
    end
  end

  # A 734 MB file over a slow link takes a while; each read is bounded.
  @impl true
  def timeout(_job), do: :timer.hours(2)

  defp mirror(image) do
    with {:ok, kernel} <- fetch(image, :kernel),
         {:ok, rootfs} <- fetch(image, :rootfs) do
      Images.mirrored(image, kernel, rootfs)
      Logger.info("guest image #{image.version} #{image.arch} mirrored")
      Images.evict_mirrors()
      :ok
    else
      {:error, reason} ->
        Images.mirror_failed(image, reason)
        Logger.warning("guest image #{image.version} #{image.arch}: #{reason}")
        {:error, reason}
    end
  end

  defp fetch(image, which) do
    {name, local, sha, size} = file(image, which)
    bundled = image.bundle_dir && Path.join(image.bundle_dir, name)

    if bundled && File.regular?(bundled) do
      with :ok <- check_file(bundled, sha, size, which), do: {:ok, bundled}
    else
      dest = Path.join([Images.store_dir(), image.id, local])

      cond do
        File.regular?(dest) and check_file(dest, sha, size, which) == :ok -> {:ok, dest}
        not room?(size) -> {:error, "no room in #{Images.store_dir()} for the #{which}"}
        true -> download(release_url(image, name), dest, sha, size, which)
      end
    end
  end

  defp file(image, :kernel),
    do: {"#{prefix(image)}.kernel", "kernel", image.kernel_sha256, image.kernel_size}

  defp file(image, :rootfs),
    do:
      {"#{prefix(image)}.rootfs.ext4.zst", "rootfs.ext4.zst", image.rootfs_sha256,
       image.rootfs_size}

  defp prefix(image), do: "crew-guest-#{image.version}-#{image.arch}"

  @doc "Where the release keeps a file: its GitHub release download."
  def release_url(image, name) do
    repo = Application.get_env(:crew, :update_repo, "ntodd/crew")
    "#{Crew.GitHub.Client.web_url()}/#{repo}/releases/download/v#{image.version}/#{name}"
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Paths are built from the image's row and the configured directories.
  defp check_file(path, sha, size, which) do
    hash =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    cond do
      File.stat!(path).size != size -> {:error, "the #{which} is the wrong size"}
      hash != sha -> {:error, "the #{which} doesn't match its SHA-256"}
      true -> :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp download(url, dest, sha, size, which) do
    File.mkdir_p!(Path.dirname(dest))
    part = dest <> ".part"
    {:ok, fd} = :file.open(part, [:write, :binary, :raw])

    # Only the artifact's own body is written: a redirect's or an error's
    # body is dropped. Req doesn't retry (Oban does, from the start), so
    # one 200 at most writes to the part.
    into = fn
      {:data, _data}, {req, %{status: status} = resp} when status != 200 ->
        {:cont, {req, resp}}

      {:data, data}, {req, resp} ->
        {ctx, n} = Req.Response.get_private(resp, :crew, {:crypto.hash_init(:sha256), 0})
        n = n + byte_size(data)

        if n > size do
          {:halt, {req, Req.Response.put_private(resp, :crew_over, true)}}
        else
          :ok = :file.write(fd, data)

          {:cont,
           {req, Req.Response.put_private(resp, :crew, {:crypto.hash_update(ctx, data), n})}}
        end
    end

    result =
      Req.get(
        Keyword.merge(
          [url: url, into: into, receive_timeout: 60_000, raw: true, retry: false],
          Application.get_env(:crew, :image_req_options, [])
        )
      )

    :ok = :file.close(fd)

    case result do
      {:ok, %{status: 200} = resp} ->
        {ctx, n} = Req.Response.get_private(resp, :crew, {:crypto.hash_init(:sha256), 0})
        hash = ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)

        cond do
          Req.Response.get_private(resp, :crew_over) ->
            discard(part, "the #{which} is larger than its manifest says")

          n != size or File.stat!(part).size != size ->
            discard(part, "the #{which} is the wrong size")

          hash != sha ->
            discard(part, "the #{which} doesn't match its SHA-256")

          true ->
            with :ok <- File.rename(part, dest), do: {:ok, dest}
        end

      {:ok, %{status: status}} ->
        discard(part, "downloading the #{which} got HTTP #{status}")

      {:error, e} ->
        discard(part, "downloading the #{which} failed: #{Exception.message(e)}")
    end
  end

  # The file, plus half a GiB to spare.
  defp room?(size), do: free_bytes(Images.store_dir()) >= size + 512 * 1_048_576

  # sobelow_skip ["Traversal.FileModule"]
  # `dir` is CREW_IMAGE_DIR.
  defp free_bytes(dir) do
    with nil <- Application.get_env(:crew, :image_free_bytes) do
      File.mkdir_p!(dir)

      case System.cmd("df", ["-Pk", dir], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split("\n", trim: true) |> List.last() |> available()
        _ -> 0
      end
    end
  end

  defp available(line) do
    case line |> String.split() |> Enum.at(3) |> Integer.parse() do
      {kib, ""} -> kib * 1024
      _ -> 0
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp discard(part, reason) do
    File.rm(part)
    {:error, reason}
  end
end
