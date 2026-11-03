defmodule CrewGuest.MetricsTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{FakeAPI, Metrics}

  @df """
  Filesystem     1024-blocks    Used Available Capacity Mounted on
  /dev/vda          20511356 5242880  15268476      26% /
  """

  describe "parsing" do
    test "/proc/stat gives busy and total jiffies" do
      assert {150, 1000} = Metrics.parse_stat(File.read!(fixture("proc/stat")))
      assert nil == Metrics.parse_stat("garbage")
    end

    test "CPU is busy over total between two samples" do
      assert Metrics.cpu_pct({150, 1000}, {250, 1200}) == 50.0
      assert Metrics.cpu_pct(nil, {250, 1200}) == 0.0
      assert Metrics.cpu_pct({150, 1000}, {150, 1000}) == 0.0
    end

    test "/proc/meminfo gives total and used (total less available) in MiB" do
      assert {3934, 1000} = Metrics.parse_meminfo(File.read!(fixture("proc/meminfo")))
    end

    test "/proc/net/dev counts eth0's bytes" do
      assert {987_654_321, 123_456_789} =
               Metrics.parse_net_dev(File.read!(fixture("proc/net/dev")))
    end

    test "without an eth0, every interface but lo counts" do
      dev = """
      Inter-|   Receive |  Transmit
       face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets
          lo:  100 1 0 0 0 0 0 0  100 1 0 0 0 0 0 0
        ens3:  200 1 0 0 0 0 0 0  300 1 0 0 0 0 0 0
        ens4:  1 1 0 0 0 0 0 0  2 1 0 0 0 0 0 0
      """

      assert {201, 302} = Metrics.parse_net_dev(dev)
    end

    test "df -Pk gives the root filesystem's used MiB" do
      assert 5120 = Metrics.parse_df(@df)
      assert nil == Metrics.parse_df("")
    end
  end

  test "a sample has the shape the guest API takes, with zeros for what's missing" do
    sample = Metrics.sample(proc_root: fixture("proc"), df: fn -> @df end)

    assert sample.mem_total_mib == 3934
    assert sample.disk_used_mib == 5120
    assert sample.net_rx_bytes == 987_654_321
    assert {:ok, _} = CrewProtocol.Guest.cast_metrics(stringify(sample), {0, sample.t})

    empty = Metrics.sample(proc_root: "/nonexistent", df: fn -> "" end)
    assert %{cpu_pct: +0.0, mem_used_mib: 0, disk_used_mib: 0, net_rx_bytes: 0} = empty
  end

  test "posts a sample on every interval" do
    api = start_supervised!(FakeAPI)

    start_supervised!(
      {Metrics,
       client: client(api), interval_ms: 50, proc_root: fixture("proc"), df: fn -> @df end}
    )

    eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) >= 2 end)
    [first | _] = FakeAPI.delivered(api, "/v1/metrics")
    assert %{mem_total_mib: 3934, disk_used_mib: 5120} = first.cast
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
