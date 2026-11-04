defmodule CrewCache.CacheCase do
  @moduledoc """
  Starting the whole cache against `CrewCache.FakeRegistry`, on
  127.0.0.1 with port 0 everywhere. Upstream names resolve through a
  fixed map (nothing touches real DNS), every compiled upstream and
  realm host points at the fake, and loopback is the only exception to
  the address policy.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias CrewCache.FakeRegistry

  @resolve %{
    "registry.test" => [{127, 0, 0, 1}],
    "storage.test" => [{127, 0, 0, 1}],
    # The fake's certificate doesn't name it.
    "wrong.test" => [{127, 0, 0, 1}],
    "lan.test" => [{192, 168, 1, 10}],
    "metadata.test" => [{169, 254, 169, 254}],
    "site.test" => [{81, 2, 3, 4}]
  }

  def resolve_map, do: @resolve

  @doc "Start the fake and the cache. Returns ports and handy URLs."
  def start_cache(dir, overrides \\ []), do: start_cache_for(FakeRegistry.start(), dir, overrides)

  @doc "Start (or restart) the cache against a fake that's already running."
  def start_cache_for(fake, dir, overrides \\ []) do
    fake = Map.take(fake, [:registry_port, :storage_port, :cacerts])
    origin = "registry.test:#{fake.registry_port}"

    origins =
      for %{upstream: upstream, realm: realm} <- CrewProtocol.Hosts.all(),
          host <- [upstream | if(realm, do: [URI.parse(realm).host], else: [])],
          into: %{},
          do: {host, origin}

    opts =
      Keyword.merge(
        [
          dir: dir,
          listen: {127, 0, 0, 1},
          https_port: 0,
          http_port: 0,
          dns: false,
          mgmt: {{127, 0, 0, 1}, 0},
          max_bytes: 512 * 1024 * 1024,
          net_except: ["127.0.0.0/8"],
          resolve: @resolve,
          origins: origins,
          upstream_cacerts: fake.cacerts
        ],
        overrides
      )

    start_supervised!({CrewCache, opts})
    ports = CrewCache.ports()

    Map.merge(fake, %{
      ports: ports,
      base: "https://127.0.0.1:#{ports.https}",
      mgmt: "http://127.0.0.1:#{ports.mgmt}"
    })
  end

  @docker_accept Enum.join(
                   [
                     "application/vnd.docker.distribution.manifest.v2+json",
                     "application/vnd.docker.distribution.manifest.list.v2+json",
                     "application/vnd.oci.image.index.v1+json",
                     "application/vnd.oci.image.manifest.v1+json"
                   ],
                   ", "
                 )

  def docker_accept, do: @docker_accept

  @doc "A request to the cache, as containerd sends it (no verification: see the TLS tests)."
  def req(ctx, method, path, opts \\ []) do
    Req.request!(
      [
        method: method,
        url: ctx.base <> path,
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: 15_000,
        connect_options: [transport_opts: [verify: :verify_none]]
      ] ++ opts
    )
  end

  @doc "`docker pull` through the mirror: HEAD the tag, GET the manifest by digest, GET each blob."
  def pull(ctx, prefix, repo, tag) do
    head =
      req(ctx, :head, "/v2/#{prefix}/#{repo}/manifests/#{tag}?ns=#{prefix}",
        headers: [{"accept", @docker_accept}]
      )

    200 = head.status
    [digest] = head.headers["docker-content-digest"]

    manifest =
      req(ctx, :get, "/v2/#{prefix}/#{repo}/manifests/#{digest}?ns=#{prefix}",
        headers: [{"accept", @docker_accept}]
      )

    200 = manifest.status
    body = Jason.decode!(manifest.body)

    blobs =
      for %{"digest" => d} <- [body["config"] | body["layers"]] do
        resp = req(ctx, :get, "/v2/#{prefix}/#{repo}/blobs/#{d}?ns=#{prefix}")
        200 = resp.status
        {d, resp.body}
      end

    %{head: head, manifest: manifest, blobs: blobs}
  end
end
