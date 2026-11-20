defmodule Crew.Repo.Migrations.ExtendDefaultRegistryAllowlist do
  use Ecto.Migration
  import Ecto.Query

  @previous ~w(registry-1.docker.io/library/* public.ecr.aws/docker/library/*
               ghcr.io/actions/* mcr.microsoft.com/*)
  @updated @previous ++
             ~w(registry-1.docker.io/hexpm/elixir quay.io/coreos/ignition-validate registry-1.docker.io/moby/buildkit)

  def up, do: upgrade(repo())

  # Compare and update in one statement so a custom policy wins. Keep
  # these lists fixed even if a future release changes the defaults again.
  def upgrade(repo) do
    repo.update_all(
      from(c in "cache_config",
        where: c.allowlist == type(^@previous, {:array, :string}),
        update: [set: [allowlist: type(^@updated, {:array, :string})]]
      ),
      []
    )
  end

  # Allowlist entries are valid on earlier releases and editable by admins.
  def down, do: :ok
end
