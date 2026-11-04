defmodule CrewAgent.CacheTest do
  @moduledoc "The agent and its box's registry cache (§15.8): config, purge, stats, mirrors."
  use ExUnit.Case, async: true

  alias CrewAgent.{Cache, Config}

  defmodule Mgmt do
    @moduledoc false
    import Plug.Conn

    def init(test), do: test

    def call(conn, test) do
      {:ok, body, conn} = read_body(conn)

      send(
        test,
        {:mgmt, conn.method, conn.request_path, get_req_header(conn, "authorization"), body}
      )

      case {conn.method, conn.request_path} do
        {"GET", "/stats"} -> json(conn, Agent.get(:"stats_#{inspect(test)}", & &1))
        {"GET", "/ca.pem"} -> send_resp(conn, 200, "PEM")
        {"POST", "/config"} -> json(conn, %{"ok" => true})
        {"POST", "/purge"} -> json(conn, %{"removed" => 3})
        _ -> send_resp(conn, 404, "")
      end
    end

    defp json(conn, body),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "crew-cache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: :"stats_#{inspect(self())}")

    server =
      start_supervised!(
        {Bandit, plug: {Mgmt, self()}, scheme: :http, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    config = %Config{
      driver: "vz",
      data_dir: dir,
      cache_mgmt_url: "http://127.0.0.1:#{port}",
      cache_mgmt_token: "tok"
    }

    %{config: config}
  end

  test "cache.config goes to the cache, and its hosts become the guests' mirrors", %{
    config: config
  } do
    assert Cache.mirrors(config) == []

    payload = %{
      enabled_hosts: ["ghcr.io", "quay.io"],
      allowlist: ["ghcr.io/actions/*"],
      parent: nil,
      rotate_ca: true
    }

    assert :ok = Cache.configure(config, payload)

    assert_received {:mgmt, "POST", "/config", ["Bearer tok"], body}

    refute Map.has_key?(Jason.decode!(body), "parent")

    assert %{
             "enabled_hosts" => ["ghcr.io", "quay.io"],
             "allowlist" => ["ghcr.io/actions/*"],
             "rotate_ca" => true,
             # The box's own networks and egress address, which the cache
             # refuses to connect to (§15.5), as VMs are refused them.
             "site4" => site4
           } = Jason.decode!(body)

    assert is_list(site4)

    assert Cache.mirrors(config) == ["ghcr.io", "quay.io"]
  end

  test "a box without a cache refuses cache commands", %{config: config} do
    assert {:error, "no_cache", _} =
             Cache.configure(%{config | cache_mgmt_url: nil}, %{enabled_hosts: []})

    assert Cache.mirrors(%{config | cache_mgmt_url: nil}) == []
  end

  test "purges are scoped", %{config: config} do
    assert :ok = Cache.purge(config, "repo:ghcr.io/mona/tools")
    assert_received {:mgmt, "POST", "/purge", _, body}
    assert Jason.decode!(body) == %{"scope" => "repo:ghcr.io/mona/tools"}
  end

  test "stats are reported as what changed since the last report" do
    first = %{
      "hosts" => [
        %{
          "host" => "ghcr.io",
          "hits" => 5,
          "misses" => 2,
          "bytes_served" => 100,
          "bytes_stored" => 40
        }
      ],
      "evictions" => 1,
      "digest_mismatches" => 0,
      "top" => [
        %{"host" => "ghcr.io", "repo" => "actions/runner", "hits" => 5, "bytes_served" => 100}
      ]
    }

    second = put_in(first, ["hosts", Access.at(0), "hits"], 9)

    {report, _} = Cache.Stats.delta(nil, first)
    assert [%{host: "ghcr.io", hits: 5, misses: 2}] = report.hosts
    assert report.evictions == 1
    assert [%{repo: "actions/runner"}] = report.top

    {report, _} = Cache.Stats.delta(first, second)
    assert [%{hits: 4, misses: 0, bytes_served: 0}] = report.hosts
    assert report.evictions == 0
    # What's stored now is a level, not a count: it's sent as it is.
    assert [%{bytes_stored: 40}] = report.hosts

    # The cache restarted: its counters start over.
    restarted = put_in(first, ["hosts", Access.at(0), "hits"], 2)
    {report, _} = Cache.Stats.delta(second, restarted)
    assert [%{hits: 2}] = report.hosts
  end

  test "the box's site4 reaches the cache when it changes, and again after a failure", %{
    config: config
  } do
    assert {:ok, ["10.0.0.0/24"]} = Cache.Stats.sync_site4(config, nil, ["10.0.0.0/24"])
    assert_received {:mgmt, "POST", "/config", _, body}
    assert Jason.decode!(body) == %{"site4" => ["10.0.0.0/24"]}

    assert {:ok, ["10.0.0.0/24"]} =
             Cache.Stats.sync_site4(config, ["10.0.0.0/24"], ["10.0.0.0/24"])

    refute_received {:mgmt, "POST", "/config", _, _}

    assert {:ok, _} =
             Cache.Stats.sync_site4(config, ["10.0.0.0/24"], ["10.0.0.0/24", "203.0.113.7/32"])

    assert_received {:mgmt, "POST", "/config", _, _}

    down = %{config | cache_mgmt_url: "http://127.0.0.1:1"}

    assert {:error, ["10.0.0.0/24"]} =
             Cache.Stats.sync_site4(down, ["10.0.0.0/24"], ["192.0.2.0/24"])
  end

  test "an agent restart keeps its baseline, unless the cache restarted too", %{config: config} do
    stats = %{"instance" => "a", "hosts" => [%{"host" => "ghcr.io", "hits" => 7}]}
    Cache.Stats.save_baseline(config, stats)

    assert Cache.Stats.baseline(config, %{"instance" => "a"}) == stats
    assert Cache.Stats.baseline(config, %{"instance" => "b"}) == nil
    # A cache that doesn't say which it is: the counters going down tell.
    assert Cache.Stats.baseline(config, %{}) == stats

    {report, _} =
      Cache.Stats.delta(stats, %{
        "instance" => "a",
        "hosts" => [%{"host" => "ghcr.io", "hits" => 9}]
      })

    assert [%{hits: 2}] = report.hosts
  end

  test "a cache that restarted between reports counts from 0, whatever its counters" do
    before = %{"instance" => "a", "hosts" => [%{"host" => "ghcr.io", "hits" => 10}]}
    after_restart = %{"instance" => "b", "hosts" => [%{"host" => "ghcr.io", "hits" => 15}]}
    {report, _} = Cache.Stats.delta(before, after_restart)
    assert [%{hits: 15}] = report.hosts
  end

  test "stats queued while the control plane is away add up, not replace each other" do
    {:ok, outbox} = CrewAgent.Outbox.start_link(name: nil)

    for {hits, stored} <- [{7, 100}, {9, 120}, {11, 90}] do
      {:ok, e} =
        CrewProtocol.Event.new("cache.stats", %{
          "t" => System.os_time(:millisecond),
          "hosts" => [
            %{
              "host" => "ghcr.io",
              "hits" => hits,
              "misses" => 1,
              "bytes_served" => 10,
              "bytes_stored" => stored
            }
          ],
          "evictions" => 1,
          "digest_mismatches" => 0
        })

      CrewAgent.Outbox.push(outbox, e)
    end

    CrewAgent.Outbox.attach(outbox, self())
    assert_receive {:outbox_deliver, %{type: "cache.stats", payload: p}, nil}
    assert [%{host: "ghcr.io", hits: 27, misses: 3, bytes_served: 30, bytes_stored: 90}] = p.hosts
    assert p.evictions == 3
    refute_receive {:outbox_deliver, %{type: "cache.stats"}, _}
  end
end
