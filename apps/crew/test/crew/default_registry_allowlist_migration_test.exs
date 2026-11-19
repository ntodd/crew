defmodule Crew.DefaultRegistryAllowlistMigrationTest do
  use Crew.DataCase

  alias Crew.Caches

  @migration Path.expand(
               "../../priv/repo/migrations/20261119000000_extend_default_registry_allowlist.exs",
               __DIR__
             )

  setup_all do
    module = Crew.Repo.Migrations.ExtendDefaultRegistryAllowlist
    unless Code.ensure_loaded?(module), do: Code.require_file(@migration)
    %{migration: module}
  end

  test "updates the old default once and respects the enabled hosts", %{migration: migration} do
    previous = ~w(registry-1.docker.io/library/* public.ecr.aws/docker/library/*
                  ghcr.io/actions/* mcr.microsoft.com/*)
    Repo.update_all(Caches.Config, set: [allowlist: previous, enabled_hosts: ["ghcr.io"]])
    assert {1, _} = migration.upgrade(Repo)
    assert {0, _} = migration.upgrade(Repo)
    config = Caches.config()

    assert config.allowlist ==
             previous ++
               ~w(registry-1.docker.io/hexpm/elixir quay.io/coreos/ignition-validate registry-1.docker.io/moby/buildkit)

    assert config.enabled_hosts == ["ghcr.io"]
  end

  test "preserves an administrator's allowlist", %{migration: migration} do
    Repo.update_all(Caches.Config, set: [allowlist: []])
    assert {0, _} = migration.upgrade(Repo)
    assert Caches.config().allowlist == []
  end
end
