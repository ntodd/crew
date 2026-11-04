defmodule Crew.Caches do
  @moduledoc """
  The boxes' registry caches (§15): the deployment's config, sent to each
  box's cache as `cache.config` when it changes and when the box joins;
  **Rotate CA** (§15.4); purges; and the `cache.stats` each box reports,
  kept 7 days with the other metrics, for the Caches page.

  An allowlist entry is added only once an image under it is fetched
  anonymously (§15.3): the allowlist is for public images, and the cache
  never stores what needed credentials.
  """
  import Ecto.Query

  alias Crew.{Activity, Agents, Audit, Boxes, Operations, Repo, Scope}
  alias Crew.Boxes.Box
  alias Crew.Caches.{Config, Stat}
  alias CrewProtocol.Hosts

  @topic "caches"

  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, @topic)
  defp changed, do: Phoenix.PubSub.broadcast(Crew.PubSub, @topic, :caches_changed)

  @doc "The deployment's cache config (the migration makes the one row)."
  def config, do: Repo.one!(from c in Config, limit: 1)

  # -- config (§15.3) ---------------------------------------------------------------

  @doc """
  Enables a subset of the hosts Crew knows. Under Design A the cache's
  CA chain names its address, not the hosts (§15.4 is written for Design
  B), so this needs no new chain.
  """
  def set_hosts(%Scope{} = scope, hosts) do
    admin(scope, fn ->
      with {:ok, config} <- Repo.update(Config.hosts_changeset(config(), hosts)) do
        Audit.log(scope, "cache.hosts", config, %{"enabled_hosts" => config.enabled_hosts})
        push_all()
        {:ok, config}
      end
    end)
  end

  @doc """
  Adds `entry` (`<host>/<repository glob>`) once `example`, an image
  under it, is fetched anonymously.
  """
  def add_entry(%Scope{} = scope, entry, example) do
    admin(scope, fn ->
      with :ok <- entry_ok(entry),
           {:ok, host, repo, ref} <- parse_example(example),
           :ok <- covers(entry, host, repo),
           :ok <- public(host, repo, ref) do
        update_allowlist(scope, "cache.allowlist_add", entry, &Enum.uniq(&1 ++ [entry]))
      end
    end)
  end

  def remove_entry(%Scope{} = scope, entry) do
    admin(scope, fn ->
      update_allowlist(scope, "cache.allowlist_remove", entry, &List.delete(&1, entry))
    end)
  end

  defp update_allowlist(scope, action, entry, fun) do
    config = config()
    config = Repo.update!(Ecto.Changeset.change(config, allowlist: fun.(config.allowlist)))
    Audit.log(scope, action, config, %{"entry" => entry})
    push_all()
    {:ok, config}
  end

  defp entry_ok(entry) do
    if Hosts.allowlist_entry?(entry), do: :ok, else: {:error, :bad_entry}
  end

  # `host/repo:tag` or `host/repo@sha256:…`.
  defp parse_example(example) do
    with [host, rest] <- String.split(String.trim(example || ""), "/", parts: 2),
         %{} <- Hosts.get(host),
         {repo, ref} when repo != "" and ref != "" <- split_ref(rest) do
      {:ok, host, repo, ref}
    else
      _ -> {:error, :bad_example}
    end
  end

  defp split_ref(rest) do
    case String.split(rest, "@", parts: 2) do
      [repo, digest] ->
        {repo, digest}

      [name] ->
        name
        |> String.split(":", parts: 2)
        |> then(fn
          [repo, tag] -> {repo, tag}
          [repo] -> {repo, "latest"}
        end)
    end
  end

  defp covers(entry, host, repo) do
    [entry_host, glob] = String.split(entry, "/", parts: 2)
    pattern = "\\A" <> (glob |> Regex.escape() |> String.replace("\\*", ".*")) <> "\\z"

    if entry_host == host and Regex.match?(Regex.compile!(pattern), repo),
      do: :ok,
      else: {:error, :example_outside}
  end

  @accept Enum.join(
            [
              "application/vnd.oci.image.index.v1+json",
              "application/vnd.oci.image.manifest.v1+json",
              "application/vnd.docker.distribution.manifest.list.v2+json",
              "application/vnd.docker.distribution.manifest.v2+json"
            ],
            ", "
          )

  # The anonymous flow, against the compiled realm only (§15.3): a
  # registry's own challenge never picks where the token comes from.
  defp public(host, repo, ref) do
    %{upstream: upstream, realm: realm} = Hosts.get(host)
    url = "https://#{upstream}/v2/#{repo}/manifests/#{ref}"

    case head(url, []) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401}} when is_binary(realm) ->
        with {:ok, token} <- anonymous_token(realm, upstream, repo),
             {:ok, %{status: 200}} <- head(url, [{"authorization", "Bearer " <> token}]) do
          :ok
        else
          _ -> {:error, :not_public}
        end

      _ ->
        {:error, :not_public}
    end
  end

  defp head(url, headers) do
    Req.request(
      Keyword.merge(
        [
          method: :head,
          url: url,
          headers: [{"accept", @accept} | headers],
          retry: false,
          receive_timeout: 10_000
        ],
        Application.get_env(:crew, :cache_req_options, [])
      )
    )
  end

  defp anonymous_token(realm, service, repo) do
    opts =
      Keyword.merge(
        [
          url: realm,
          params: [service: service, scope: "repository:#{repo}:pull"],
          retry: false,
          receive_timeout: 10_000
        ],
        Application.get_env(:crew, :cache_req_options, [])
      )

    case Req.get(opts) do
      {:ok, %{status: 200, body: %{"token" => t}}} when is_binary(t) -> {:ok, t}
      {:ok, %{status: 200, body: %{"access_token" => t}}} when is_binary(t) -> {:ok, t}
      _ -> :error
    end
  end

  # -- the CA (§15.4) ---------------------------------------------------------------

  @doc "Regenerates every box cache's CA chain; VMs started afterwards get the new root."
  def rotate_ca(%Scope{} = scope) do
    admin(scope, fn ->
      config = config()

      config =
        Repo.update!(Ecto.Changeset.change(config, ca_generation: config.ca_generation + 1))

      Audit.log(scope, "cache.rotate_ca", config, %{"generation" => config.ca_generation})
      Activity.record("ca_rotated", "#{scope.user.login} rotated the registry caches' CA")
      push_all()
      {:ok, config}
    end)
  end

  # -- pushing it to boxes ----------------------------------------------------------

  @doc """
  Sends `cache.config` to `box_id`, asking for a new CA chain when the
  box's cache is behind the deployment's generation (a rotation, or a
  change of hosts, while it was offline). Called when a box joins.
  """
  def push(box_id) do
    config = config()
    box = Boxes.get!(box_id)
    rotate? = box.cache_ca_generation < config.ca_generation

    payload = %{
      enabled_hosts: config.enabled_hosts,
      allowlist: config.allowlist,
      parent: nil,
      rotate_ca: rotate?
    }

    with {:ok, %{status: "dispatched"}} <- Operations.dispatch(box_id, "cache.config", payload) do
      if rotate?,
        do:
          Repo.update_all(from(b in Box, where: b.id == ^box_id),
            set: [cache_ca_generation: config.ca_generation]
          )

      :ok
    end
  end

  defp push_all do
    changed()
    for box <- Boxes.list(), Agents.online?(box.id), do: push(box.id)
    :ok
  end

  @doc "Purges a box's cache (`all`, `host:<host>` or `repo:<host>/<repository>`). Audited."
  def purge(%Scope{} = scope, box_id, purge_scope) do
    admin(scope, fn ->
      with {:ok, op} <- Operations.dispatch(box_id, "cache.purge", %{scope: purge_scope}) do
        Audit.log(scope, "cache.purge", Boxes.get!(box_id), %{"scope" => purge_scope})
        {:ok, op}
      end
    end)
  end

  # -- stats (§15.8, §17.3) ---------------------------------------------------------

  @doc "Stores a box's `cache.stats` (its `t` is Unix milliseconds)."
  def record_stats(box_id, p) do
    t = div(p.t, 1000)

    rows =
      for h <- p.hosts do
        %{
          box_id: box_id,
          t: t,
          host: h.host,
          hits: h.hits,
          misses: h.misses,
          bytes_served: h.bytes_served,
          bytes_stored: h.bytes_stored,
          mismatches: 0,
          evictions: 0
        }
      end

    box_wide = %{
      box_id: box_id,
      t: t,
      host: "*",
      hits: 0,
      misses: 0,
      bytes_served: 0,
      bytes_stored: 0,
      mismatches: p.digest_mismatches,
      evictions: p.evictions
    }

    Repo.insert_all(Stat, [box_wide | rows])

    top = for e <- p[:top] || [], do: Map.new(e, fn {k, v} -> {to_string(k), v} end)
    Repo.update_all(from(b in Box, where: b.id == ^box_id), set: [cache_top: top])
    changed()
    :ok
  end

  @doc "A box cache's last day: hits, misses, hit rate, bytes served and stored, mismatches, top images."
  def box_summary(box_id, now \\ System.os_time(:second)) do
    since = now - 86_400

    sums =
      Repo.one(
        from s in Stat,
          where: s.box_id == ^box_id and s.t >= ^since,
          select: %{
            hits: coalesce(sum(s.hits), 0),
            misses: coalesce(sum(s.misses), 0),
            bytes_served: coalesce(sum(s.bytes_served), 0),
            bytes_stored: coalesce(sum(s.bytes_stored), 0),
            mismatches: coalesce(sum(s.mismatches), 0),
            evictions: coalesce(sum(s.evictions), 0)
          }
      )

    sums = Map.new(sums, fn {k, v} -> {k, to_int(v)} end)
    sums = %{sums | bytes_stored: stored(box_id, since)}
    total = sums.hits + sums.misses

    box = Repo.get(Box, box_id)

    top =
      for e <- (box && box.cache_top) || [],
          do: %{
            host: e["host"],
            repo: e["repo"],
            hits: e["hits"],
            bytes_served: e["bytes_served"]
          }

    Map.merge(sums, %{hit_rate: if(total > 0, do: Float.round(sums.hits / total, 3)), top: top})
  end

  # A level per host: each host's last report in the window.
  defp stored(box_id, since) do
    last =
      from s in Stat,
        where: s.box_id == ^box_id and s.t >= ^since and s.host != "*",
        group_by: s.host,
        select: %{host: s.host, t: max(s.t)}

    Repo.one(
      from s in Stat,
        join: l in subquery(last),
        on: s.host == l.host and s.t == l.t,
        where: s.box_id == ^box_id,
        select: coalesce(sum(s.bytes_stored), 0)
    )
    |> to_int()
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: round(n)

  @doc "Drops stats older than `cutoff` (Unix seconds), with the other metrics (§9.4)."
  def prune(cutoff), do: Repo.delete_all(from s in Stat, where: s.t < ^cutoff)

  defp admin(scope, fun) do
    if Scope.admin?(scope), do: fun.(), else: {:error, :unauthorized}
  end
end
