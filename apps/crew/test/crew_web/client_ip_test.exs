defmodule CrewWeb.ClientIPTest do
  use ExUnit.Case, async: false

  alias CrewWeb.ClientIP

  test "a direct client is its peer address" do
    assert ClientIP.resolve({100, 64, 0, 7}, []) == "100.64.0.7"
  end

  test "behind a local proxy (tailscale serve), the address the proxy appended is the client" do
    # A client can send its own X-Forwarded-For; the proxy appends the real
    # address, so only the last entry is trusted.
    headers = [{"x-forwarded-for", "6.6.6.6, 100.64.0.9"}]
    assert ClientIP.resolve({127, 0, 0, 1}, headers) == "100.64.0.9"

    assert ClientIP.resolve({0, 0, 0, 0, 0, 0, 0, 1}, [{"X-Forwarded-For", "fd7a::5"}]) ==
             "fd7a::5"
  end

  test "forwarded headers from anyone but a local proxy are ignored" do
    assert ClientIP.resolve({100, 64, 0, 7}, [{"x-forwarded-for", "1.2.3.4"}]) == "100.64.0.7"
  end

  describe "trusted proxies (CREW_TRUSTED_PROXIES)" do
    setup do
      before = Application.fetch_env(:crew, :trusted_proxies)
      Application.put_env(:crew, :trusted_proxies, "172.16.0.0/12, fd00::/8")
      on_exit(fn -> restore(:trusted_proxies, before) end)
    end

    test "a peer in a trusted range is a proxy, as loopback is" do
      headers = [{"x-forwarded-for", "6.6.6.6, 100.64.0.9"}]
      # Docker's bridge gateway, under docker/compose.yml.
      assert ClientIP.resolve({172, 18, 0, 1}, headers) == "100.64.0.9"
      assert ClientIP.resolve({0xFD00, 0, 0, 0, 0, 0, 0, 1}, headers) == "100.64.0.9"
      # An IPv4 peer on an IPv6 socket.
      assert ClientIP.resolve({0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 1}, headers) == "100.64.0.9"
    end

    test "anyone outside them still can't say who they are" do
      headers = [{"x-forwarded-for", "1.2.3.4"}]
      assert ClientIP.resolve({172, 32, 0, 1}, headers) == "172.32.0.1"
      assert ClientIP.resolve({100, 64, 0, 7}, headers) == "100.64.0.7"
    end
  end

  test "with several forwarded headers, the last one's last entry is the client" do
    before = Application.fetch_env(:crew, :trusted_proxies)
    Application.put_env(:crew, :trusted_proxies, "10.0.0.0/8")
    on_exit(fn -> restore(:trusted_proxies, before) end)

    # The client's own header first, then the one the proxy added.
    headers = [{"x-forwarded-for", "6.6.6.6"}, {"x-forwarded-for", "100.64.0.9"}]
    assert ClientIP.resolve({10, 0, 0, 1}, headers) == "100.64.0.9"
  end

  test "gateway: the container's default gateway, from its routes" do
    header =
      "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"

    route = fn dest, gw, mask -> "eth0\t#{dest}\t#{gw}\t0003\t0\t0\t0\t#{mask}\t0\t0\t0\n" end
    default = route.("00000000", "010012AC", "00000000")
    # 0.0.0.0/1 via 10.0.0.2: a destination of 0, but not the default.
    half = route.("00000000", "0200000A", "00000080")
    local = route.("000012AC", "00000000", "0000FFFF")

    assert Crew.Config.parse_cidrs!("gateway", routes: header <> half <> default <> local) ==
             [{{172, 18, 0, 1}, 32}]

    for routes <- [header <> half <> local, header, ""] do
      assert_raise ArgumentError, fn -> Crew.Config.parse_cidrs!("gateway", routes: routes) end
    end
  end

  test "trusted proxy ranges must be CIDRs" do
    assert Crew.Config.parse_cidrs!("") == []
    assert [{{10, 0, 0, 0}, 8}] = Crew.Config.parse_cidrs!("10.0.0.0/8")

    for bad <- [
          "10.0.0.0",
          "10.0.0.0/33",
          "fd00::/129",
          "nope/8",
          "10.0.0.0/x",
          "10.0.0.0/-0",
          "10.0.0.0/+8",
          "::ffff:192.0.2.1/128"
        ] do
      assert_raise ArgumentError, fn -> Crew.Config.parse_cidrs!(bad) end
    end
  end

  test "a forwarded value that isn't an address falls back to the peer" do
    for junk <- ["", "  ", "unknown", "1.2.3.4.5", "<script>"] do
      assert ClientIP.resolve({127, 0, 0, 1}, [{"x-forwarded-for", junk}]) == "127.0.0.1"
    end
  end

  test "works from a conn and from socket connect info" do
    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-forwarded-for", "100.64.0.3"}]
    }

    assert ClientIP.from_conn(conn) == "100.64.0.3"

    info = %{
      peer_data: %{address: {127, 0, 0, 1}},
      x_headers: [{"x-forwarded-for", "100.64.0.4"}]
    }

    assert ClientIP.from_connect_info(info) == "100.64.0.4"
    assert ClientIP.from_connect_info(%{}) == "unknown"
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:crew, key, value)
  defp restore(key, :error), do: Application.delete_env(:crew, key)
end
