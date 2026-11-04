defmodule Crew.Images do
  @moduledoc """
  Guest images (§13.1, §20.4): what's registered, which is each arch's
  default (the pinned one, else the newest), and each box's copy.

  Preparing an image on a box (`image.prepare`) is retried after 1, 5,
  then 15 minutes, never once a pass (§8.3).

  An image is registered from its signed manifest: the control plane's
  own image carries its release's manifests (§20.1), registered at boot,
  and `Crew.Images.Mirror` then fetches the kernel and root filesystem
  from the release and checks them against the manifest. Until that's
  done, an image can't be the default.
  """
  import Ecto.Query

  require Logger

  alias Crew.Images.{BoxImage, Image, Manifest, Mirror}
  alias Crew.Repo

  @retries_min [1, 5, 15]

  # A prepare quiet this long is sent again.
  @quiet_s 30 * 60

  def list, do: Repo.all(from i in Image, order_by: [desc: i.registered_at])
  def get(id), do: Repo.get(Image, id)

  @doc """
  Registers an image from its manifest's exact bytes and their signature
  (base64), checked with the release key (§13.1). The same release again
  is the image already registered; a different manifest under a version
  that's registered is refused.
  """
  def register_signed(manifest, signature, opts \\ []) when is_binary(manifest) do
    signature = String.trim(signature || "")

    with key when is_binary(key) <- Crew.Config.release_public_key() || {:error, :no_release_key},
         :ok <- CrewProtocol.Auth.verify_manifest(manifest, signature, key),
         {:ok, fields} <- Manifest.parse(manifest) |> manifest_error() do
      sha = sha256(manifest)

      case Repo.get_by(Image, version: fields.version, arch: fields.arch) do
        # Registered again at boot: a mirror that never finished is tried again.
        %Image{manifest_sha256: ^sha} = image ->
          {:ok, ensure_mirror(image)}

        %Image{} ->
          {:error, :conflict}

        nil ->
          fields
          |> Map.merge(%{
            manifest: manifest,
            manifest_sha256: sha,
            signature: signature,
            mirror_state: "pending",
            bundle_dir: opts[:bundle_dir]
          })
          |> register()
          |> case do
            {:ok, image} -> {:ok, ensure_mirror(image)}
            error -> error
          end
      end
    end
  end

  defp ensure_mirror(image) do
    if image.mirror_state != "ready", do: Oban.insert!(Mirror.new(%{image_id: image.id}))
    image
  end

  defp manifest_error({:error, reason}), do: {:error, {:manifest, reason}}
  defp manifest_error(ok), do: ok

  @doc """
  Registers the signed manifests in `dir` (`crew-guest-*.manifest.json`,
  each with its `.manifest.sig`): the control plane's bundled release.
  """
  def register_bundle(dir) do
    results =
      for path <- Path.wildcard(Path.join(dir, "crew-guest-*.manifest.json")) do
        sig = String.replace_suffix(path, ".manifest.json", ".manifest.sig")

        result =
          with {:ok, manifest} <- File.read(path),
               {:ok, signature} <- File.read(sig) do
            register_signed(manifest, signature, bundle_dir: dir)
          end

        case result do
          {:ok, image} ->
            {:ok, image}

          {:error, reason} ->
            Logger.warning(
              "guest image #{Path.basename(path)} wasn't registered: #{inspect(reason)}"
            )

            {:error, {Path.basename(path), reason}}
        end
      end

    %{
      registered: Enum.count(results, &match?({:ok, _}, &1)),
      failed: for({:error, f} <- results, do: f)
    }
  end

  @topic "images"

  @doc "Subscribes the caller to `:images_changed`: registrations, mirrors, pins and box states."
  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, @topic)

  defp changed, do: Phoenix.PubSub.broadcast(Crew.PubSub, @topic, :images_changed)

  @doc """
  Pins an image as its arch's default (§20.4); rolling back is pinning
  the previous one. Only a mirrored image can be pinned. Audited.
  """
  def pin(%Crew.Scope{} = scope, %Image{} = image) do
    cond do
      not Crew.Scope.admin?(scope) ->
        {:error, :unauthorized}

      image.mirror_state != "ready" ->
        {:error, :not_mirrored}

      true ->
        {:ok, image} =
          Repo.transaction(fn ->
            Repo.update_all(from(i in Image, where: i.arch == ^image.arch and i.pinned),
              set: [pinned: false]
            )

            Repo.update!(Ecto.Changeset.change(image, pinned: true))
          end)

        Crew.Audit.log(scope, "image.pin", image, %{
          "version" => image.version,
          "arch" => image.arch
        })

        changed()
        Crew.Scheduler.poke()
        {:ok, image}
    end
  end

  @doc "Unpins an image, so its arch follows the newest again. Audited."
  def unpin(%Crew.Scope{} = scope, %Image{} = image) do
    if Crew.Scope.admin?(scope) do
      image = Repo.update!(Ecto.Changeset.change(image, pinned: false))

      Crew.Audit.log(scope, "image.unpin", image, %{
        "version" => image.version,
        "arch" => image.arch
      })

      changed()
      Crew.Scheduler.poke()
      {:ok, image}
    else
      {:error, :unauthorized}
    end
  end

  @doc "Where the control plane keeps the image files it mirrors."
  def store_dir, do: Application.get_env(:crew, :image_dir, "/var/lib/crew/images")

  @doc "Records a finished mirror: the files boxes download."
  def mirrored(%Image{} = image, kernel_path, rootfs_path) do
    image =
      image
      |> Ecto.Changeset.change(
        kernel_path: kernel_path,
        rootfs_path: rootfs_path,
        mirror_state: "ready",
        mirror_error: nil,
        mirrored_at: DateTime.utc_now()
      )
      |> Repo.update!()

    if defaults()[image.arch].default == image.id do
      Crew.Activity.record(
        "image_rollout",
        "Guest image #{image.version} (#{image.arch}) is the default: boxes are preparing it"
      )
    end

    changed()
    Crew.Scheduler.poke()
    image
  end

  def mirror_failed(%Image{} = image, error) do
    image =
      image
      |> Ecto.Changeset.change(mirror_state: "failed", mirror_error: error)
      |> Repo.update!()

    changed()
    image
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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
      # An image whose files the control plane doesn't have yet can't be
      # prepared anywhere, so it isn't a default until it has them.
      images =
        Repo.all(
          from i in Image,
            where: i.arch == ^arch and i.mirror_state == "ready",
            order_by: [desc: i.registered_at, desc: i.id]
        )

      pinned = Enum.find(images, & &1.pinned)
      default = pinned || List.first(images)
      recent = images |> Enum.take(2) |> Enum.map(& &1.id)

      {arch,
       %{
         default: default && default.id,
         recent_defaults: Enum.uniq(Enum.reject([default && default.id | recent], &is_nil/1)),
         order: Enum.map(images, & &1.id)
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
  def box_images_all, do: Repo.all(BoxImage)

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

    changed()
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
        mirror_state: "ready",
        kernel_sha256: sha,
        kernel_size: 0,
        rootfs_sha256: sha,
        rootfs_size: 0,
        runner_version: "dev"
      })
    end
  end
end
