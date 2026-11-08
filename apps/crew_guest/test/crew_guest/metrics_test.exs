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

    test "/proc/vmstat gives the kernel's OOM kill count" do
      assert 2 == Metrics.parse_vmstat_oom(File.read!(fixture("proc/vmstat")))
      assert nil == Metrics.parse_vmstat_oom("nr_free_pages 5\n")
      assert nil == Metrics.parse_vmstat_oom("")
    end

    test "/proc/pressure gives the some and full stall totals, in microseconds" do
      assert %{some: 1_500_000, full: 0} =
               Metrics.parse_pressure(File.read!(fixture("proc/pressure/cpu")))

      assert %{some: 20_000, full: 5_000} =
               Metrics.parse_pressure(File.read!(fixture("proc/pressure/memory")))

      # Kernels before 5.13 have no full line for CPU.
      assert %{some: 7} ==
               Metrics.parse_pressure("some avg10=0.00 avg60=0.00 avg300=0.00 total=7\n")

      assert %{} == Metrics.parse_pressure("")
      assert %{} == Metrics.parse_pressure("some avg10=x total=-3\nfull total=\n")
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

  test "a sample has the OOM kill count and the pressure totals, when the kernel has them" do
    sample = Metrics.sample(proc_root: fixture("proc"), df: fn -> @df end)

    assert %{oom_kills: 2, cpu_some_us: 1_500_000, mem_some_us: 20_000, mem_full_us: 5_000} =
             sample

    assert {:ok, cast} = CrewProtocol.Guest.cast_metrics(stringify(sample), {0, sample.t})
    assert %{oom_kills: 2, cpu_some_us: 1_500_000, mem_full_us: 5_000} = cast

    # Without them the fields aren't sent, so the agent knows they're unknown.
    empty = Metrics.sample(proc_root: "/nonexistent", df: fn -> "" end)

    for key <- [:oom_kills, :cpu_some_us, :mem_some_us, :mem_full_us, :mem_peak_mib],
        do: refute(Map.has_key?(empty, key), "#{key}")
  end

  test "a reader that raises costs only its own reading" do
    sample = Metrics.sample(proc_root: fixture("proc"), df: fn -> raise "df exploded" end)

    assert %{disk_used_mib: 0, mem_total_mib: 3934, oom_kills: 2} = sample
  end

  describe "the memory high-water mark" do
    setup do
      dir = Path.join(System.tmp_dir!(), "crew-guest-proc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      api = start_supervised!(FakeAPI)
      %{dir: dir, api: api}
    end

    # MemTotal 4096 MiB, with `used` MiB of it in use.
    defp meminfo(dir, used) do
      total = 4096 * 1024

      File.write!(
        Path.join(dir, "meminfo"),
        "MemTotal: #{total} kB\nMemAvailable: #{total - used * 1024} kB\n"
      )
    end

    # Timers far off, so the test drives each peek and post itself.
    defp start_metrics(api, dir) do
      start_supervised!(
        {Metrics,
         client: client(api),
         interval_ms: 3_600_000,
         peek_ms: 3_600_000,
         proc_root: dir,
         df: fn -> @df end}
      )
    end

    defp drive(pid, msg) do
      send(pid, msg)
      :sys.get_state(pid)
    end

    test "is the most memory used between posts, and starts again after each", %{
      dir: dir,
      api: api
    } do
      meminfo(dir, 1000)
      pid = start_metrics(api, dir)

      meminfo(dir, 3500)
      drive(pid, :peek)
      meminfo(dir, 1200)
      drive(pid, :peek)
      drive(pid, :tick)

      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 1 end)
      [first] = FakeAPI.delivered(api, "/v1/metrics")
      assert %{mem_used_mib: 1200, mem_peak_mib: 3500} = first.cast
      eventually(fn -> :sys.get_state(pid).posting == nil end)

      drive(pid, :peek)
      drive(pid, :tick)
      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 2 end)
      [_, second] = FakeAPI.delivered(api, "/v1/metrics")
      assert %{mem_used_mib: 1200, mem_peak_mib: 1200} = second.cast
    end

    test "is at least what the post itself reads", %{dir: dir, api: api} do
      meminfo(dir, 1000)
      pid = start_metrics(api, dir)
      drive(pid, :peek)
      meminfo(dir, 2000)
      drive(pid, :tick)

      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 1 end)

      assert [%{cast: %{mem_used_mib: 2000, mem_peak_mib: 2000}}] =
               FakeAPI.delivered(api, "/v1/metrics")
    end

    test "keeps reading memory while a post is slow", %{dir: dir, api: api} do
      FakeAPI.respond(api, "/v1/metrics", [{:delay, 1_500, {204, nil}}, {204, nil}])
      meminfo(dir, 1000)
      pid = start_metrics(api, dir)
      drive(pid, :tick)

      # The post is in flight; a spike now is still read.
      meminfo(dir, 3900)
      {elapsed, _} = :timer.tc(fn -> drive(pid, :peek) end, :millisecond)
      assert elapsed < 500
      meminfo(dir, 1000)

      # A post due while one's in flight is skipped, and its peak kept.
      drive(pid, :tick)
      eventually(fn -> :sys.get_state(pid).posting == nil end)
      assert length(FakeAPI.delivered(api, "/v1/metrics")) == 1
      drive(pid, :tick)
      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 2 end)

      assert [%{cast: %{mem_peak_mib: 1000}}, %{cast: %{mem_peak_mib: 3900}}] =
               FakeAPI.delivered(api, "/v1/metrics")
    end

    test "a post that crashes doesn't take the sampler with it", %{dir: dir, api: api} do
      FakeAPI.respond(api, "/v1/metrics", [:drop, {204, nil}])
      meminfo(dir, 1000)
      pid = start_metrics(api, dir)

      drive(pid, :tick)
      eventually(fn -> FakeAPI.requests(api, "/v1/metrics") != [] end)
      eventually(fn -> :sys.get_state(pid).posting == nil end)
      drive(pid, :tick)
      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 1 end)
      assert Process.alive?(pid)
    end

    test "survives proc files that are garbage or go away", %{dir: dir, api: api} do
      meminfo(dir, 1000)
      pid = start_metrics(api, dir)

      File.write!(Path.join(dir, "meminfo"), <<0, 255, 1, 2>>)
      drive(pid, :peek)
      File.rm!(Path.join(dir, "meminfo"))
      File.mkdir_p!(Path.join(dir, "meminfo"))
      drive(pid, :peek)
      drive(pid, :tick)

      eventually(fn -> length(FakeAPI.delivered(api, "/v1/metrics")) == 1 end)
      assert Process.alive?(pid)
    end
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
