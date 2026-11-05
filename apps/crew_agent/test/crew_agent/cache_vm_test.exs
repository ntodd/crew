defmodule CrewAgent.CacheVMTest do
  @moduledoc """
  A `mac-vz` box's cache VM (§12.1, §15.6), from the agent on the Mac:
  found by its MAC in vmnet's DHCP leases, managed on its address, its
  reboot state reported, and restarted through launchd.
  """
  # The handler's test puts a config, which is global.
  use ExUnit.Case, async: false

  alias CrewAgent.{Cache, CacheVM, Config}

  defmodule Mgmt do
    @moduledoc false
    import Plug.Conn

    def init(test), do: test

    def call(conn, test) do
      send(test, {:mgmt, conn.method, conn.request_path, get_req_header(conn, "authorization")})

      case {conn.method, conn.request_path} do
        {"GET", "/host"} ->
          body = %{
            "reboot_required" => true,
            "packages" => ["flatcar-4800.0.0"],
            "boot_id" => "0f7a3b2c-1111-4222-8333-444455556666"
          }

          conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))

        {"GET", "/ca.pem"} ->
          send_resp(conn, 200, "PEM")

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  @mac "52:54:00:0a:0b:0c"
  @boot "0f7a3b2c-1111-4222-8333-444455556666"

  # vmnet's bootpd writes lease blocks like these; it drops leading
  # zeros from the MAC's octets and keeps the expiry in hex.
  @leases """
  {
  \tname=crew-cache
  \tip_address=192.168.64.9
  \thw_address=1,52:54:0:a:b:c
  \tidentifier=1,52:54:0:a:b:c
  \tlease=0x672a0000
  }
  {
  \tname=m3max
  \tip_address=192.168.64.4
  \thw_address=1,52:54:0:c7:e0:1
  \tidentifier=1,52:54:0:c7:e0:1
  \tlease=0x672b0000
  }
  {
  \tname=crew-cache
  \tip_address=192.168.64.12
  \thw_address=1,52:54:0:a:b:c
  \tidentifier=1,52:54:0:a:b:c
  \tlease=0x672c0000
  }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "crew-cachevm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    leases = Path.join(dir, "dhcpd_leases")
    File.write!(leases, @leases)

    config = %Config{
      driver: "vz",
      data_dir: dir,
      vz_cache: %{addr: nil, mac: @mac, mgmt_port: 7780, leases: leases},
      cache_mgmt_token: "tok"
    }

    %{config: config, dir: dir}
  end

  defp cache(config, changes),
    do: %{config | vz_cache: Map.merge(config.vz_cache, Map.new(changes))}

  defp with_mgmt(config) do
    server =
      start_supervised!(
        {Bandit, plug: {Mgmt, self()}, scheme: :http, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    cache(config, addr: "127.0.0.1", mgmt_port: port)
  end

  describe "its address" do
    test "is its newest lease in vmnet's leases, by MAC", %{config: config} do
      assert CacheVM.address(config) == "192.168.64.12"
    end

    test "CREW_VZ_CACHE_ADDR wins over the leases", %{config: config} do
      assert CacheVM.address(cache(config, addr: "192.168.64.50")) == "192.168.64.50"
    end

    test "is nil without a lease, a cache VM or a readable leases file", %{config: config} do
      assert CacheVM.address(cache(config, mac: "52:54:00:ff:ff:ff")) == nil
      assert CacheVM.address(cache(config, mac: nil)) == nil
      assert CacheVM.address(cache(config, leases: "/nonexistent")) == nil
    end

    test "ignores anything that isn't an IPv4 address", %{config: config, dir: dir} do
      File.write!(
        config.vz_cache.leases,
        "{\n\tip_address=nope\n\thw_address=1,52:54:0:a:b:c\n\tlease=0x1\n}\n"
      )

      assert CacheVM.address(config) == nil
      assert CacheVM.address(cache(config, addr: "10.0.0.1; rm")) == nil
      assert File.exists?(dir)
    end
  end

  describe "management" do
    test "is on the cache VM's address, port 7780, with the token", %{config: config} do
      assert CacheVM.mgmt_url(config) == "http://192.168.64.12:7780"

      assert CacheVM.mgmt_url(%{config | cache_mgmt_url: "http://10.1.2.3:9"}) ==
               "http://10.1.2.3:9"

      assert CacheVM.mgmt_url(cache(config, mac: nil)) == nil
    end

    test "the cache's CA comes from the cache VM", %{config: config} do
      config = with_mgmt(config)
      assert {:ok, "PEM"} = Cache.ca_pem(config)
      assert_received {:mgmt, "GET", "/ca.pem", ["Bearer tok"]}
    end
  end

  describe "its reboot state" do
    test "is GET /host's, for box.reboot's cache_vm", %{config: config} do
      assert CacheVM.reboot(with_mgmt(config)) ==
               %{required: true, packages: ["flatcar-4800.0.0"], boot_id: @boot}
    end

    test "is nil without a cache VM, or when it doesn't answer", %{config: config} do
      assert CacheVM.reboot(cache(config, mac: nil)) == nil
      assert CacheVM.reboot(cache(config, addr: "127.0.0.1", mgmt_port: 1)) == nil
    end

    test "rides on box.reboot as cache_vm", %{config: config} do
      payload = CrewAgent.Reporter.reboot_payload(with_mgmt(config))
      assert payload.cache_vm == %{required: true, packages: ["flatcar-4800.0.0"], boot_id: @boot}
      assert payload.can_restart == false
      assert {:ok, _} = CrewProtocol.Event.new("box.reboot", payload)

      assert CrewAgent.Reporter.reboot_payload(cache(config, mac: nil)).cache_vm == nil
    end
  end

  describe "cachevm.restart" do
    test "on the boot it was asked about, asks launchd through its trigger file", %{
      config: config
    } do
      config = with_mgmt(config)
      assert :ok = CacheVM.restart(config, @boot)
      trigger = Path.join([config.data_dir, "run", "restart-cachevm"])
      assert File.read!(trigger) == @boot <> "\n"
    end

    test "on another boot, it already restarted", %{config: config} do
      config = with_mgmt(config)
      other = "11111111-2222-4333-8444-555555555555"
      assert {:ok, %{"already" => true}} = CacheVM.restart(config, other)
      refute File.exists?(Path.join([config.data_dir, "run", "restart-cachevm"]))
    end

    test "is an error when the cache VM doesn't answer", %{config: config} do
      config = cache(config, addr: "127.0.0.1", mgmt_port: 1)
      assert {:error, "cachevm_unreachable", _} = CacheVM.restart(config, @boot)
    end

    test "the handler takes it on vz, and only there", %{config: config} do
      base = Config.get()
      on_exit(fn -> Config.put(base) end)
      {:ok, cmd} = CrewProtocol.Command.new("cachevm.restart", %{"boot_id" => @boot})

      Config.put(with_mgmt(config))
      assert :ok = CrewAgent.Handler.handle(cmd)

      Config.put(%{config | driver: "firecracker"})
      assert {:error, "unsupported", _} = CrewAgent.Handler.handle(cmd)
    end
  end
end
