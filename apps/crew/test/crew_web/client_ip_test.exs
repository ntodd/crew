defmodule CrewWeb.ClientIPTest do
  use ExUnit.Case, async: true

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
end
