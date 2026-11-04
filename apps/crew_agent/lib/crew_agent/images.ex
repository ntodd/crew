defmodule CrewAgent.Images do
  @moduledoc """
  Guest images on this box (§13.1): `images/<image_id>/` holds `kernel`,
  `rootfs.ext4` (read-only), `manifest.json` and `manifest.sig`.

  Preparing one (download, verify, decompress) is
  `CrewAgent.Images.Prepare`, which builds it in `images/.<image_id>.tmp/`
  and renames it into place. This is what VMs need from it: whether an
  image is ready, and a clone of its root filesystem (§12.5), which is
  never a full copy.
  """

  alias CrewAgent.Config
  alias CrewAgent.Images.Prepare
  alias CrewProtocol.Text

  def dir(config, image_id), do: Path.join(Config.images_dir(config), image_id)

  @doc "Where a prepare builds the image. Not a UUID, so never in the inventory."
  def tmp_dir(config, image_id), do: Path.join(Config.images_dir(config), ".#{image_id}.tmp")

  @doc "Whether the image is prepared here."
  def ready?(config, image_id) do
    d = dir(config, image_id)

    File.exists?(Path.join(d, "rootfs.ext4")) and File.exists?(Path.join(d, "kernel")) and
      File.exists?(Path.join(d, "ready"))
  end

  def kernel(config, image_id), do: Path.join(dir(config, image_id), "kernel")

  @doc """
  Clones the image's root filesystem to `dest` and sizes it to the VM's
  disk: `clonefile(2)` on macOS (`cp -c`), `cp --reflink=always` on
  Linux. Fails rather than copying.
  """
  def clone(config, image_id, dest, disk_gib) do
    src = Path.join(dir(config, image_id), "rootfs.ext4")

    args =
      case :os.type() do
        {:unix, :darwin} -> ["-c", src, dest]
        _ -> ["--reflink=always", src, dest]
      end

    case System.cmd("cp", args, stderr_to_stdout: true) do
      {_, 0} ->
        File.chmod!(dest, 0o600)
        {_, 0} = System.cmd("truncate", ["-s", "#{disk_gib}G", dest], stderr_to_stdout: true)
        dest

      {out, _} ->
        raise "cloning the root filesystem failed (no full copies): #{String.trim(out)}"
    end
  end

  @doc "The images here and their states, for `box.inventory`."
  def inventory(config) do
    case File.ls(Config.images_dir(config)) do
      {:ok, ids} ->
        for id <- ids, CrewProtocol.uuid?(id) do
          %{id: id, state: if(ready?(config, id), do: "ready", else: "failed")}
        end

      _ ->
        []
    end
  end

  @doc """
  `image.prepare` (§13.1): download, verify and convert
  (`CrewAgent.Images.Prepare`, which takes `opts`). An image that's
  already ready is reported ready at once. The null driver has nothing to
  download, so the image is marked ready.
  """
  def prepare(image, config \\ Config.get(), opts \\ []) do
    cond do
      config.driver == "null" ->
        d = dir(config, image.id)
        File.mkdir_p!(d)
        for f <- ["kernel", "rootfs.ext4", "ready"], do: File.write!(Path.join(d, f), "")
        report(image.id, "ready", 100, nil)
        :ok

      config.dev and is_binary(config.dev_image_dir) ->
        prepare_from_dir(config, image, config.dev_image_dir)

      ready?(config, image.id) ->
        report(image.id, "ready", 100, nil)
        :ok

      true ->
        Prepare.run(config, image, opts)
    end
  end

  def remove(image_id) do
    config = Config.get()
    File.rm_rf(dir(config, image_id))
    File.rm_rf(tmp_dir(config, image_id))
    :ok
  end

  # Development (CREW_DEV_IMAGE_DIR): a local `Image` (or `kernel`) and
  # `rootfs.ext4`, cloned in, for a real driver without a download.
  defp prepare_from_dir(config, image, src) do
    d = dir(config, image.id)
    kernel = Enum.find(["kernel", "Image"], &File.exists?(Path.join(src, &1)))

    with true <- kernel != nil and File.exists?(Path.join(src, "rootfs.ext4")),
         :ok <- File.mkdir_p(d),
         {_, 0} <-
           System.cmd("cp", ["-c", Path.join(src, kernel), Path.join(d, "kernel")],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd("cp", ["-c", Path.join(src, "rootfs.ext4"), Path.join(d, "rootfs.ext4")],
             stderr_to_stdout: true
           ),
         :ok <- File.chmod(Path.join(d, "rootfs.ext4"), 0o440),
         :ok <- File.write(Path.join(d, "ready"), "") do
      report(image.id, "ready", 100, nil)
      :ok
    else
      other ->
        report(image.id, "failed", 0, "copying the development image failed: #{inspect(other)}")
        {:error, "image_failed", "copying the development image failed"}
    end
  end

  @doc false
  def report(id, state, progress, error) do
    {:ok, event} =
      CrewProtocol.Event.new("image.state", %{
        image_id: id,
        state: state,
        progress: progress,
        error: error && error |> Text.scrub() |> Text.cut(1024) |> elem(0)
      })

    CrewAgent.Outbox.push(event)
  end
end
