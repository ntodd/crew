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

    assert Jason.decode!(body) == %{
             "enabled_hosts" => ["ghcr.io", "quay.io"],
             "allowlist" => ["ghcr.io/actions/*"],
             "parent" => nil,
             "rotate_ca" => true
           }

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

    # The cache restarted: its counters start over.
    restarted = put_in(first, ["hosts", Access.at(0), "hits"], 2)
    {report, _} = Cache.Stats.delta(second, restarted)
    assert [%{hits: 2}] = report.hosts
  end
end
