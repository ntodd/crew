defmodule Crew.Images.Image do
  @moduledoc "A guest image: kernel plus root filesystem, per arch, signed (§13.1)."
  use Crew.Schema

  schema "images" do
    field :version, :string
    field :arch, :string
    field :manifest, :binary
    field :manifest_sha256, :string
    field :signature, :string
    field :kernel_sha256, :string
    field :kernel_size, :integer
    field :rootfs_sha256, :string
    field :rootfs_size, :integer
    field :kernel_path, :string
    field :rootfs_path, :string
    field :runner_version, :string
    field :docker_version, :string
    field :registered_at, :utc_datetime_usec
    field :pinned, :boolean, default: false
    timestamps()
  end
end
