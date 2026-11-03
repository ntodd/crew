defmodule CrewAgent.Images do
  @moduledoc """
  Guest images on this box (§13.1): `images/<image_id>/` holds `kernel`,
  `rootfs.ext4` (read-only), `manifest.json` and `manifest.sig`.

  Preparing (download, verify, decompress) comes with the guest image;
  this is what VMs need from it: whether an image is ready, and a clone
  of its root filesystem (§12.5), which is never a full copy.
  """

  alias CrewAgent.Config

  def dir(config, image_id), do: Path.join(Config.images_dir(config), image_id)

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
  `image.prepare` (§13.1). The null driver has nothing to download, so
  the image is marked ready. The real drivers' download, verify and
  convert come with the guest image.
  """
  def prepare(image) do
    config = Config.get()

    if config.driver == "null" do
      d = dir(config, image.id)
      File.mkdir_p!(d)
      for f <- ["kernel", "rootfs.ext4", "ready"], do: File.write!(Path.join(d, f), "")
      report(image.id, "ready", 100, nil)
      :ok
    else
      {:error, "unsupported", "image preparation isn't in this agent yet"}
    end
  end

  def remove(image_id) do
    File.rm_rf(dir(Config.get(), image_id))
    :ok
  end

  defp report(id, state, progress, error) do
    {:ok, event} =
      CrewProtocol.Event.new("image.state", %{
        image_id: id,
        state: state,
        progress: progress,
        error: error
      })

    CrewAgent.Outbox.push(event)
  end
end
