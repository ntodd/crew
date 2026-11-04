defmodule CrewAgent.SiteTest do
  @moduledoc "site4 (§14.2): the site's own addresses a guest mustn't reach."
  use ExUnit.Case, async: false

  alias CrewAgent.{Config, Site}

  test "connected subnets come from the interfaces, without loopback or Crew's own ranges" do
    ifaddrs = [
      {~c"lo0", [flags: [:up, :loopback], addr: {127, 0, 0, 1}, netmask: {255, 0, 0, 0}]},
      {~c"en0",
       [
         flags: [:up],
         addr: {192, 168, 1, 20},
         netmask: {255, 255, 255, 0},
         addr: {0xFE80, 0, 0, 0, 0, 0, 0, 1},
         netmask: {65_535, 65_535, 65_535, 65_535, 0, 0, 0, 0}
       ]},
      {~c"en1", [flags: [:up], addr: {203, 0, 113, 77}, netmask: {255, 255, 255, 248}]},
      {~c"utun3",
       [flags: [:up, :pointtopoint], addr: {100, 101, 102, 103}, netmask: {255, 255, 255, 255}]},
      {~c"bridge100", [flags: [:up], addr: {10, 200, 0, 1}, netmask: {255, 255, 255, 252}]},
      {~c"en5", [flags: [], addr: {198, 51, 100, 9}, netmask: {255, 255, 255, 0}]}
    ]

    assert Site.connected(ifaddrs, "10.200.0.0/16") == [
             "192.168.1.0/24",
             "203.0.113.72/29",
             "100.101.102.103/32"
           ]
  end

  test "site4 is the connected subnets, the egress address and CREW_EXTRA_BLOCKED, once each" do
    config = %{Config.get() | extra_blocked: ["198.51.100.0/24", "192.168.1.0/24"]}

    assert Site.site4(config, ["192.168.1.0/24"], "198.51.100.200") == [
             "192.168.1.0/24",
             "198.51.100.200/32",
             "198.51.100.0/24"
           ]

    assert Site.site4(config, [], nil) == ["198.51.100.0/24", "192.168.1.0/24"]
  end

  test "the echo service's answer is an IPv4 address or nothing" do
    assert Site.parse_egress("203.0.113.9\n") == "203.0.113.9"
    assert Site.parse_egress("<html>nope</html>") == nil
    assert Site.parse_egress("2001:db8::1") == nil
  end

  @tag :tmp_dir
  test "on a Firecracker box the egress address is kept for crew-net (agent/egress4)", %{
    tmp_dir: dir
  } do
    config = %{Config.get() | driver: "firecracker", data_dir: dir}
    Site.record_egress(config, "198.51.100.20")
    assert Site.egress() == "198.51.100.20"
    assert File.read!(Path.join([dir, "agent", "egress4"])) == "198.51.100.20\n"

    # vz keeps it in memory: each VM's helper is given site4 at start.
    other = Path.join(dir, "vz")
    Site.record_egress(%{config | driver: "vz", data_dir: other}, "198.51.100.21")
    refute File.exists?(Path.join([other, "agent", "egress4"]))
  after
    :persistent_term.erase({Site, :egress})
  end
end
