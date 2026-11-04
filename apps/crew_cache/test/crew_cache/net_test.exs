defmodule CrewCache.NetTest do
  use ExUnit.Case, async: true

  alias CrewCache.Net

  describe "parse_cidr/1" do
    test "takes a CIDR or a bare address" do
      assert {:ok, {{10, 0, 0, 0}, 8}} = Net.parse_cidr("10.1.2.3/8")
      assert {:ok, {{203, 0, 113, 7}, 32}} = Net.parse_cidr("203.0.113.7")
      assert {:ok, {{0, 0, 0, 0}, 0}} = Net.parse_cidr(" 0.0.0.0/0 ")
    end

    test "refuses anything else" do
      for bad <- ["", "10.0.0.0/33", "10.0.0/8", "::1/128", "a.b.c.d", "10.0.0.0/-1", "1.2.3.4/x"] do
        assert :error = Net.parse_cidr(bad), bad
      end
    end
  end

  describe "refused?/2" do
    test "refuses every blocked4 range (§14.2)" do
      policy = Net.policy([], [])

      for ip <- [
            {0, 1, 2, 3},
            {10, 199, 0, 1},
            {100, 64, 0, 1},
            {100, 127, 255, 255},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 0, 0, 1},
            {192, 0, 2, 1},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {198, 19, 255, 255},
            {198, 51, 100, 1},
            {203, 0, 113, 1},
            {224, 0, 0, 1},
            {240, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert Net.refused?(ip, policy), inspect(ip)
      end
    end

    test "allows public addresses" do
      policy = Net.policy([], [])

      for ip <- [
            {1, 1, 1, 1},
            {140, 82, 112, 3},
            {172, 32, 0, 1},
            {100, 128, 0, 1},
            {198, 20, 0, 1}
          ] do
        refute Net.refused?(ip, policy), inspect(ip)
      end
    end

    test "refuses site4 too" do
      policy = Net.policy(["203.0.114.0/24", "8.8.8.8/32"], [])
      assert Net.refused?({203, 0, 114, 9}, policy)
      assert Net.refused?({8, 8, 8, 8}, policy)
      refute Net.refused?({8, 8, 4, 4}, policy)
    end

    test "refuses IPv6, which the cache never dials" do
      assert Net.refused?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}, Net.policy([], []))
    end

    test "test-only exceptions are limited to loopback" do
      policy = Net.policy([], ["127.0.0.0/8", "10.0.0.0/8", "0.0.0.0/0"])
      refute Net.refused?({127, 0, 0, 1}, policy)
      assert Net.refused?({10, 0, 0, 1}, policy)
      assert Net.refused?({192, 168, 0, 1}, policy)
    end
  end

  test "connected/1 lists the up, non-loopback IPv4 networks" do
    ifaddrs = [
      {~c"lo0", [flags: [:up, :loopback], addr: {127, 0, 0, 1}, netmask: {255, 0, 0, 0}]},
      {~c"en0",
       [
         flags: [:up, :broadcast],
         addr: {0xFE80, 0, 0, 0, 0, 0, 0, 1},
         netmask: {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, 0, 0},
         addr: {81, 2, 3, 4},
         netmask: {255, 255, 255, 0}
       ]},
      {~c"en1", [flags: [:broadcast], addr: {82, 0, 0, 1}, netmask: {255, 255, 0, 0}]}
    ]

    assert Net.connected(ifaddrs) == ["81.2.3.0/24"]
  end
end
