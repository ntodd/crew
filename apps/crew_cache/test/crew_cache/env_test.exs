defmodule CrewCache.EnvTest do
  use ExUnit.Case, async: true

  alias CrewCache.Env

  test "the defaults (§21.3)" do
    config = Env.config(%{})
    assert config[:dir] == "/srv/crew/cache"
    assert config[:mode] == :box
    assert config[:listen] == {10, 199, 0, 1}
    assert config[:https_port] == 443
    assert config[:http_port] == 80
    assert config[:dns_port] == 53
    assert config[:dns] == true
    assert config[:registry] == true
    assert config[:dns_upstreams] == [{{1, 1, 1, 1}, 53}, {{9, 9, 9, 9}, 53}]
    assert config[:mgmt] == {{127, 0, 0, 1}, 7780}
    assert config[:mgmt_token] == nil
    assert config[:max_bytes] == nil
    assert config[:extra_blocked] == []
  end

  test "every variable" do
    config =
      Env.config(%{
        "CREW_DATA_DIR" => "/data",
        "CREW_CACHE_MODE" => "box",
        "CREW_CACHE_LISTEN" => "192.168.64.5",
        "CREW_CACHE_HTTPS_PORT" => "8443",
        "CREW_CACHE_HTTP_PORT" => "off",
        "CREW_CACHE_DNS_PORT" => "5353",
        "CREW_DNS_UPSTREAMS" => "8.8.8.8, 1.0.0.1:5353",
        "CREW_CACHE_MAX_GIB" => "40",
        "CREW_CACHE_MGMT_LISTEN" => "100.64.0.9:7780",
        "CREW_CACHE_MGMT_TOKEN" => "tok",
        "CREW_EXTRA_BLOCKED" => "203.0.114.0/24, 8.8.4.4/32"
      })

    assert config[:dir] == "/data/cache"
    assert config[:listen] == {192, 168, 64, 5}
    assert config[:https_port] == 8443
    assert config[:http_port] == nil
    assert config[:dns_port] == 5353
    assert config[:dns_upstreams] == [{{8, 8, 8, 8}, 53}, {{1, 0, 0, 1}, 5353}]
    assert config[:max_bytes] == 40 * 1024 * 1024 * 1024
    assert config[:mgmt] == {{100, 64, 0, 9}, 7780}
    assert config[:mgmt_token] == "tok"
    assert config[:extra_blocked] == ["203.0.114.0/24", "8.8.4.4/32"]
  end

  test "off leaves a part out" do
    config =
      Env.config(%{
        "CREW_CACHE_DNS_PORT" => "off",
        "CREW_CACHE_HTTPS_PORT" => "off",
        "CREW_CACHE_MGMT_LISTEN" => "off"
      })

    assert config[:dns] == false
    assert config[:registry] == false
    assert config[:mgmt] == nil
  end

  test "CREW_CACHE_DIR wins over CREW_DATA_DIR" do
    assert Env.config(%{"CREW_DATA_DIR" => "/data", "CREW_CACHE_DIR" => "/elsewhere"})[:dir] ==
             "/elsewhere"
  end

  test "bad values are refused at start" do
    for {var, value} <- [
          {"CREW_CACHE_LISTEN", "nowhere"},
          {"CREW_CACHE_HTTPS_PORT", "70000"},
          {"CREW_DNS_UPSTREAMS", "dns.google"},
          {"CREW_CACHE_MAX_GIB", "lots"},
          {"CREW_CACHE_MGMT_LISTEN", "127.0.0.1"},
          {"CREW_EXTRA_BLOCKED", "10.0.0.0/33"},
          {"CREW_CACHE_MODE", "proxy"}
        ] do
      assert_raise ArgumentError, ~r/#{var}/, fn -> Env.config(%{var => value}) end
    end
  end

  test "parent mode is read, and refused when the cache starts" do
    assert Env.config(%{"CREW_CACHE_MODE" => "parent"})[:mode] == :parent
  end

  test "the test-only settings can't come from the environment" do
    keys = Env.config(%{}) |> Keyword.keys()

    for key <- [:net_except, :resolve, :origins, :upstream_cacerts, :host_root] do
      refute key in keys
    end
  end
end
