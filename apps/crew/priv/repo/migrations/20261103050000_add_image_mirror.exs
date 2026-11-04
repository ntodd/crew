defmodule Crew.Repo.Migrations.AddImageMirror do
  use Ecto.Migration

  # Signed guest images and the control plane's copy of their files
  # (§13.1, §20.1): the decompressed root filesystem's hash from the
  # manifest, and where the mirror stands.
  def change do
    alter table(:images) do
      add :rootfs_ext4_sha256, :string
      add :rootfs_ext4_size, :bigint
      add :kernel_version, :string
      add :packages_lock_sha256, :string
      add :mirror_state, :string, null: false, default: "ready"
      add :mirror_error, :text
      add :mirrored_at, :utc_datetime_usec
      # The control plane's bundled release directory, when the image
      # came from it: its files may be there already.
      add :bundle_dir, :string
    end
  end
end
