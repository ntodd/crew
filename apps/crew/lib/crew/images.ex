defmodule Crew.Images do
  @moduledoc """
  Guest images (§13.1, §20.4): what's registered, which is each arch's
  default (the pinned one, else the newest), and each box's copy.

  Preparing an image on a box (`image.prepare`) is retried after 1, 5,
  then 15 minutes, never once a pass (§8.3). Signature checks and
  mirroring of release assets come with the guest image build.
  """
  import Ecto.Query

  alias Crew.Images.{BoxImage, Image}
  alias Crew.Repo

  @retries_min [1, 5, 15]

  # A prepare quiet this long is sent again.
  @quiet_s 30 * 60

  def list, do: Repo.all(from i in Image, order_by: [desc: i.registered_at])
  def get(id), do: Repo.get(Image, id)

  def register(attrs) do
    now = DateTime.utc_now()

    %Image{registered_at: now}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:version, :arch])
    |> case do
      # On a conflict the struct carries the id generated for the insert
      # that didn't happen, so the stored row is read back.
      {:ok, _} -> {:ok, Repo.get_by!(Image, version: attrs.version, arch: attrs.arch)}
      other -> other
    end
  end

  @doc "Each arch's default and the recent defaults a box may keep using (§8.3)."
  def defaults do
    for arch <- ["arm64", "x64"], into: %{} do
      images =
        Repo.all(
          from i in Image, where: i.arch == ^arch, order_by: [desc: i.registered_at, desc: i.id]
        )

      pinned = Enum.find(images, & &1.pinned)
      default = pinned || List.first(images)
      recent = images |> Enum.take(2) |> Enum.map(& &1.id)

      {arch,
       %{
         default: default && default.id,
         recent_defaults: Enum.uniq(Enum.reject([default && default.id | recent], &is_nil/1))
       }}
    end
  end

  @doc "`{box_id, image_id} => state` for every box image. A failed one due for a retry reads `retry`."
  def box_states(now \\ DateTime.utc_now()) do
    quiet = DateTime.add(now, -@quiet_s)

    for bi <- Repo.all(BoxImage), into: %{} do
      state =
        cond do
          (bi.state == "failed" and bi.retry_at) && DateTime.compare(bi.retry_at, now) != :gt ->
            "retry"

          # A prepare that never reported back (lost with a disconnect).
          bi.state in ~w(downloading verifying converting) and
              DateTime.compare(bi.updated_at, quiet) == :lt ->
            "retry"

          true ->
            bi.state
        end

      {{bi.box_id, bi.image_id}, state}
    end
  end

  @doc """
  A box's inventory lists the images its agent has: any other image the
  control plane has on record for it is forgotten, so it's prepared
  again. One updated in the last minute is kept: its prepare may still
  be on the way.
  """
  def forget_unlisted(box_id, listed_ids, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -60)

    Repo.delete_all(
      from bi in BoxImage,
        where: bi.box_id == ^box_id and bi.image_id not in ^listed_ids and bi.updated_at < ^cutoff
    )

    :ok
  end

  def box_images(box_id), do: Repo.all(from bi in BoxImage, where: bi.box_id == ^box_id)

  @doc "Records an image's state on a box (from `image.state`, or a prepare being sent)."
  def put_box_state(box_id, image_id, state, attrs \\ %{}) do
    now = DateTime.utc_now()
    existing = Repo.get_by(BoxImage, box_id: box_id, image_id: image_id)
    attempts = (existing && existing.attempts) || 0

    {attempts, retry_at} =
      if state == "failed" do
        n = attempts + 1
        {n, DateTime.add(now, 60 * Enum.at(@retries_min, n - 1, List.last(@retries_min)))}
      else
        {if(state == "ready", do: 0, else: attempts), nil}
      end

    row = %{
      box_id: box_id,
      image_id: image_id,
      state: state,
      progress: attrs[:progress] || 0,
      error: attrs[:error],
      attempts: attempts,
      retry_at: retry_at,
      updated_at: now
    }

    Repo.insert_all(BoxImage, [row],
      on_conflict: {:replace, [:state, :progress, :error, :attempts, :retry_at, :updated_at]},
      conflict_target: [:box_id, :image_id]
    )

    :ok
  end

  @doc "The `image.prepare` payload for an image (§10.3)."
  def prepare_payload(%Image{} = image) do
    base = Crew.Config.base_url()

    %{
      "image" => %{
        "id" => image.id,
        "version" => image.version,
        "arch" => image.arch,
        "kernel" => %{
          "url" => "#{base}/images/#{image.id}/kernel",
          "sha256" => image.kernel_sha256,
          "size" => image.kernel_size
        },
        "rootfs" => %{
          "url" => "#{base}/images/#{image.id}/rootfs",
          "sha256" => image.rootfs_sha256,
          "size" => image.rootfs_size
        },
        "manifest" => Base.encode64(image.manifest),
        "signature" => image.signature
      }
    }
  end

  @doc """
  Development (CREW_DEV): one placeholder image per arch, so the null
  driver's boxes have something usable. It's never sent anywhere real.
  """
  def register_dev_images do
    sha = String.duplicate("0", 64)

    for arch <- ["arm64", "x64"] do
      register(%{
        version: "0.0.0-dev",
        arch: arch,
        manifest: ~s({"version":"0.0.0-dev","arch":"#{arch}"}),
        manifest_sha256:
          :crypto.hash(:sha256, ~s({"version":"0.0.0-dev","arch":"#{arch}"}))
          |> Base.encode16(case: :lower),
        signature: Base.encode64(:binary.copy(<<0>>, 64)),
        kernel_sha256: sha,
        kernel_size: 0,
        rootfs_sha256: sha,
        rootfs_size: 0,
        runner_version: "dev"
      })
    end
  end
end
