defmodule Crew.CachesTest do
  @moduledoc "The registry cache's config, CA rotation and stats (§15.3, §15.4, §15.8, §17.3)."
  use Crew.VMCase

  alias Crew.Caches

  defp admin, do: Crew.Scope.for_user(user_fixture(role: "admin"))

  # A registry's anonymous flow: a 401 with a realm, then a token.
  defp registry(public?) do
    Req.Test.stub(Crew.Caches, fn conn ->
      auth = Plug.Conn.get_req_header(conn, "authorization")

      cond do
        conn.request_path == "/token" and public? ->
          Req.Test.json(conn, %{"token" => "anon"})

        conn.request_path == "/token" ->
          Plug.Conn.send_resp(conn, 403, "")

        auth == ["Bearer anon"] ->
          conn
          |> Plug.Conn.put_resp_header(
            "docker-content-digest",
            "sha256:" <> String.duplicate("a", 64)
          )
          |> Plug.Conn.send_resp(200, "")

        true ->
          conn
          |> Plug.Conn.put_resp_header(
            "www-authenticate",
            ~s(Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:x:pull")
          )
          |> Plug.Conn.send_resp(401, "")
      end
    end)
  end

  test "the defaults: every known host, the default allowlist" do
    config = Caches.config()
    assert config.enabled_hosts == CrewProtocol.Hosts.names()
    assert "ghcr.io/actions/*" in config.allowlist
  end

  test "enabling hosts: only known ones, audited, and every online box is told", %{box: box} do
    online(box)
    assert {:error, %Ecto.Changeset{}} = Caches.set_hosts(admin(), ["ghcr.io", "evil.example"])
    assert {:ok, _} = Caches.set_hosts(admin(), ["ghcr.io", "public.ecr.aws"])

    cmd = assert_command("cache.config")
    assert cmd.payload.enabled_hosts == ["ghcr.io", "public.ecr.aws"]
    # Design A's chain names the cache's address, not the hosts, so a
    # change of hosts needs no new CA (docs/architecture.md).
    refute cmd.payload.rotate_ca
    assert Repo.exists?(from e in Crew.Audit.Event, where: e.action == "cache.hosts")

    assert {:error, :unauthorized} =
             Caches.set_hosts(Crew.Scope.for_user(user_fixture()), ["ghcr.io"])
  end

  test "an allowlist entry is added only once a public image under it is fetched anonymously",
       %{box: box} do
    online(box)
    registry(true)
    assert {:ok, config} = Caches.add_entry(admin(), "ghcr.io/mona/*", "ghcr.io/mona/tools:1.0")
    assert "ghcr.io/mona/*" in config.allowlist
    cmd = assert_command("cache.config")
    assert "ghcr.io/mona/*" in cmd.payload.allowlist
    refute cmd.payload.rotate_ca

    registry(false)

    assert {:error, :not_public} =
             Caches.add_entry(admin(), "ghcr.io/secret/*", "ghcr.io/secret/app:latest")

    assert {:error, :example_outside} =
             Caches.add_entry(admin(), "ghcr.io/mona/*", "ghcr.io/other/x:1")

    assert {:error, :bad_entry} =
             Caches.add_entry(admin(), "evil.example/x/*", "evil.example/x/y:1")

    refute "ghcr.io/secret/*" in Caches.config().allowlist

    assert {:ok, config} = Caches.remove_entry(admin(), "ghcr.io/mona/*")
    refute "ghcr.io/mona/*" in config.allowlist
  end

  test "rotating the CA: a new generation, every box told, audited", %{box: box} do
    online(box)
    gen = Caches.config().ca_generation
    assert {:ok, config} = Caches.rotate_ca(admin())
    assert config.ca_generation == gen + 1
    assert assert_command("cache.config").payload.rotate_ca
    assert Repo.exists?(from e in Crew.Activity.Event, where: e.kind == "ca_rotated")
  end

  test "a box that joins is sent the config", %{box: box} do
    online(box)
    Crew.Agents.joined(box, %{agent_version: "0.1.0", protocol_version: 1}, nil)
    cmd = assert_command("cache.config")
    refute cmd.payload.rotate_ca
  end

  test "purging: everywhere or one box, scoped", %{box: box} do
    online(box)
    assert {:ok, _} = Caches.purge(admin(), box.id, "repo:ghcr.io/mona/tools")
    assert assert_command("cache.purge").payload.scope == "repo:ghcr.io/mona/tools"
    assert {:error, _} = Caches.purge(admin(), box.id, "repo:evil/x")
  end

  test "stats: stored per box and host, summed for the page", %{box: box} do
    now = System.os_time(:millisecond)

    for {t, hits} <- [{now - 120_000, 3}, {now - 60_000, 5}] do
      agent_event(box, "cache.stats", %{
        "t" => t,
        "hosts" => [
          %{
            "host" => "ghcr.io",
            "hits" => hits,
            "misses" => 1,
            "bytes_served" => 1000,
            "bytes_stored" => 400
          }
        ],
        "top" => [
          %{
            "host" => "ghcr.io",
            "repo" => "actions/runner",
            "hits" => hits,
            "bytes_served" => 900
          }
        ],
        "evictions" => 0,
        "digest_mismatches" => 0
      })
    end

    summary = Caches.box_summary(box.id)
    assert summary.hits == 8 and summary.misses == 2
    assert summary.hit_rate == 0.8
    assert summary.bytes_served == 2000
    # What's stored is a level: the last report's, not a sum.
    assert summary.bytes_stored == 400
    assert [%{repo: "actions/runner", host: "ghcr.io"}] = summary.top
  end

  test "stats older than 7 days are pruned, as metrics are", %{box: box} do
    old = System.os_time(:millisecond) - 8 * 86_400_000

    agent_event(box, "cache.stats", %{
      "t" => old,
      "hosts" => [%{"host" => "ghcr.io", "hits" => 1}]
    })

    Crew.Metrics.prune()
    assert Caches.box_summary(box.id).hits == 0
  end
end
