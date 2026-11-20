defmodule CrewProtocol.Hosts do
  @moduledoc """
  The registries crew_cache knows (§15.3), compiled into every release.
  `cache.config` can enable a subset of these and nothing else; adding a
  host means a Crew release.
  """

  @hosts [
    %{
      host: "registry-1.docker.io",
      prefix: "docker.io",
      upstream: "registry-1.docker.io",
      realm: "https://auth.docker.io/token"
    },
    %{host: "ghcr.io", prefix: "ghcr.io", upstream: "ghcr.io", realm: "https://ghcr.io/token"},
    %{
      host: "public.ecr.aws",
      prefix: "public.ecr.aws",
      upstream: "public.ecr.aws",
      realm: "https://public.ecr.aws/token"
    },
    %{host: "quay.io", prefix: "quay.io", upstream: "quay.io", realm: "https://quay.io/v2/auth"},
    %{
      host: "registry.k8s.io",
      prefix: "registry.k8s.io",
      upstream: "registry.k8s.io",
      realm: nil
    },
    %{
      host: "mcr.microsoft.com",
      prefix: "mcr.microsoft.com",
      upstream: "mcr.microsoft.com",
      realm: nil
    },
    %{host: "gcr.io", prefix: "gcr.io", upstream: "gcr.io", realm: "https://gcr.io/v2/token"}
  ]

  @default_allowlist ~w(registry-1.docker.io/library/* public.ecr.aws/docker/library/*
                        ghcr.io/actions/* mcr.microsoft.com/* registry-1.docker.io/hexpm/elixir
                        quay.io/coreos/ignition-validate registry-1.docker.io/moby/buildkit)

  def all, do: @hosts
  def names, do: Enum.map(@hosts, & &1.host)
  def get(host), do: Enum.find(@hosts, &(&1.host == host))
  def default_allowlist, do: @default_allowlist

  @doc "The token audience from a registry's Bearer challenge. The realm stays compiled in."
  def token_service(challenge, fallback) do
    with [scheme, params] <- String.split(challenge || "", " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         [_, service] <- Regex.run(~r/(?:^|,)\s*service="([^"]+)"/i, params) do
      service
    else
      _ -> fallback
    end
  end

  @entry ~r/\A([a-z0-9.-]+)\/([a-z0-9._\/*-]{1,255})\z/

  @doc "Whether `entry` is `<known host>/<repository glob>`."
  def allowlist_entry?(entry) when is_binary(entry) do
    case Regex.run(@entry, entry) do
      [_, host, glob] -> host in names() and not String.contains?(glob, ["..", "//"])
      nil -> false
    end
  end

  def allowlist_entry?(_), do: false
end
