defmodule Crew.MetricsTest do
  @moduledoc "Reading box samples back for charts (§16.5)."
  use Crew.DataCase
  use ExUnitProperties

  alias Crew.Metrics

  describe "box_series/3" do
    test "averages a box's samples over each step, oldest first" do
      box = box_fixture()
      other = box_fixture()
      since = 1_800_000_000

      box_metric_fixture(box, since + 1, cpu_pct: 10.0, mem_used_mib: 1000, load1: 1.0)
      box_metric_fixture(box, since + 6, cpu_pct: 30.0, mem_used_mib: 3000, load1: 3.0)
      box_metric_fixture(box, since + 11, cpu_pct: 50.0, mem_used_mib: 5000, load1: 5.0)
      box_metric_fixture(other, since + 1, cpu_pct: 99.0)

      assert [first, second] = Metrics.box_series(box.id, since, 10)

      assert %{t: ^since, cpu_pct: 20.0, mem_used_mib: 2000, mem_total_mib: 131_072, load1: 2.0} =
               first

      assert %{t: t, cpu_pct: 50.0, mem_used_mib: 5000} = second
      assert t == since + 10
    end

    test "starts at `since`, not the start of the bucket it falls in" do
      box = box_fixture()
      since = 1_800_000_005
      box_metric_fixture(box, since + 1, cpu_pct: 40.0)
      box_metric_fixture(box, since - 1, cpu_pct: 90.0)

      assert [%{t: ^since, cpu_pct: 40.0}] = Metrics.box_series(box.id, since, 10)
    end
  end

  describe "record_vm/2" do
    setup do
      %{vm: vm_fixture(box_fixture())}
    end

    @base %{
      t: 1_800_000_000_000,
      cpu_pct: 12.5,
      mem_used_mib: 900,
      mem_total_mib: 8192,
      disk_used_mib: 2048,
      net_rx_bps: 1000,
      net_tx_bps: 200,
      host_cpu_pct: 50.0,
      host_rss_mib: 1200
    }

    test "stores a newer guest's high-water mark, OOM kills and pressure", %{vm: vm} do
      readings = %{
        mem_peak_mib: 3000,
        oom_kills: 1,
        cpu_pressure_pct: 25.0,
        mem_pressure_pct: 5.0,
        mem_full_pressure_pct: 1.0
      }

      :ok = Metrics.record_vm(vm, Map.merge(@base, readings))

      assert [%{t: 1_800_000_000, mem_used_mib: 900} = m] = Metrics.vm_series(vm.id)

      assert %{
               mem_peak_mib: 3000,
               oom_kills: 1,
               cpu_pressure_pct: 25.0,
               mem_pressure_pct: 5.0,
               mem_full_pressure_pct: 1.0
             } = m
    end

    test "an older agent's sample has none of them", %{vm: vm} do
      :ok = Metrics.record_vm(vm, @base)

      assert [%{mem_peak_mib: nil, oom_kills: nil, cpu_pressure_pct: nil}] =
               Metrics.vm_series(vm.id)
    end
  end

  describe "job_summary/3" do
    setup do
      %{vm: vm_fixture(box_fixture())}
    end

    @start ~U[2026-11-03 10:00:00Z]
    @finish ~U[2026-11-03 10:01:00Z]

    defp at(seconds), do: DateTime.to_unix(@start) + seconds

    test "counts only the samples from the job's start to its finish", %{vm: vm} do
      # Booting and waiting for the job: idle, with a little memory.
      for s <- [-30, -25, -20, -15, -10, -5],
          do: vm_metric_fixture(vm, at(s), cpu_pct: 1.0, mem_used_mib: 300)

      for s <- [5, 10, 15], do: vm_metric_fixture(vm, at(s), cpu_pct: 90.0, mem_used_mib: 3000)
      vm_metric_fixture(vm, at(20), cpu_pct: 30.0, mem_used_mib: 2000, disk_used_mib: 9000)

      # The VM powering off after the job, past two sample intervals.
      vm_metric_fixture(vm, at(71), cpu_pct: 100.0, mem_used_mib: 7000)

      assert %{peak_mem_mib: 3000, peak_cpu_pct: 90.0, avg_cpu_pct: 75.0, peak_disk_mib: 9000} =
               Metrics.job_summary(vm, @start, @finish)
    end

    # The agent stamps a guest reading when it sends it, up to one
    # interval after the guest took it, and the reading covers the
    # interval before that: a sample up to two intervals past the finish
    # can still hold the job's last seconds.
    test "keeps the samples that can still hold the job's last seconds", %{vm: vm} do
      vm_metric_fixture(vm, at(30), mem_used_mib: 1000)
      vm_metric_fixture(vm, at(70), mem_used_mib: 4000)

      assert %{peak_mem_mib: 4000} = Metrics.job_summary(vm, @start, @finish)
    end

    # Times are whole seconds, so a sample in the job's first second is
    # stamped with its start.
    test "keeps a sample stamped with the job's start", %{vm: vm} do
      vm_metric_fixture(vm, at(0), mem_used_mib: 5000)
      vm_metric_fixture(vm, at(5), mem_used_mib: 1000)

      assert %{peak_mem_mib: 5000} = Metrics.job_summary(vm, @start, @finish)
    end

    test "a job shorter than one sample gets every sample of its VM", %{vm: vm} do
      vm_metric_fixture(vm, at(-5), cpu_pct: 20.0, mem_used_mib: 500)
      vm_metric_fixture(vm, at(20), cpu_pct: 40.0, mem_used_mib: 700)

      assert %{peak_mem_mib: 700, avg_cpu_pct: 30.0} =
               Metrics.job_summary(vm, @start, DateTime.add(@start, 1))
    end

    test "without both times, every sample counts", %{vm: vm} do
      vm_metric_fixture(vm, at(-5), cpu_pct: 20.0)
      vm_metric_fixture(vm, at(10), cpu_pct: 40.0)

      assert %{avg_cpu_pct: 30.0} = Metrics.job_summary(vm, nil, @finish)
      assert %{avg_cpu_pct: 30.0} = Metrics.job_summary(vm, @start, nil)
    end

    test "a VM with no samples has no summary", %{vm: vm} do
      assert nil == Metrics.job_summary(vm, @start, @finish)
    end
  end

  describe "job_summary/3 for right-sizing (§7.5)" do
    setup do
      %{vm: vm_fixture(box_fixture(), vcpus: 4, memory_mib: 8192)}
    end

    defp at4(seconds), do: DateTime.to_unix(~U[2026-11-03 10:00:00Z]) + seconds

    defp summary(vm),
      do: Metrics.job_summary(vm, ~U[2026-11-03 10:00:00Z], ~U[2026-11-03 10:01:00Z])

    test "has the shape the job ran on", %{vm: vm} do
      vm_metric_fixture(vm, at4(5))
      assert %{vcpus: 4, memory_mib: 8192} = summary(vm)
    end

    test "peak memory counts the guest's high-water mark between samples", %{vm: vm} do
      vm_metric_fixture(vm, at4(5), mem_used_mib: 1000, mem_peak_mib: 3500)
      vm_metric_fixture(vm, at4(10), mem_used_mib: 2000, mem_peak_mib: 2100)
      # An older guest's sample has no high-water mark.
      vm_metric_fixture(vm, at4(15), mem_used_mib: 1500, mem_peak_mib: nil)

      assert %{peak_mem_mib: 3500} = summary(vm)
    end

    test "oom is set when the guest's OOM kill count rose while the job ran", %{vm: vm} do
      vm_metric_fixture(vm, at4(-5), oom_kills: 0)
      vm_metric_fixture(vm, at4(5), oom_kills: 0)
      vm_metric_fixture(vm, at4(10), oom_kills: 1)

      assert %{oom: true} = summary(vm)
    end

    test "an OOM kill from before the job started doesn't count", %{vm: vm} do
      vm_metric_fixture(vm, at4(-5), oom_kills: 1)
      vm_metric_fixture(vm, at4(5), oom_kills: 1)

      assert %{oom: false} = summary(vm)
    end

    test "without the count (an older guest) there's no OOM to report", %{vm: vm} do
      vm_metric_fixture(vm, at4(5))
      assert %{oom: false} = summary(vm)
    end

    test "pressure is the average over the job, and unknown from an older guest", %{vm: vm} do
      vm_metric_fixture(vm, at4(-5), cpu_pressure_pct: 90.0, mem_pressure_pct: 90.0)

      vm_metric_fixture(vm, at4(5),
        cpu_pressure_pct: 10.0,
        mem_pressure_pct: 1.0,
        mem_full_pressure_pct: 0.0
      )

      vm_metric_fixture(vm, at4(10),
        cpu_pressure_pct: 30.0,
        mem_pressure_pct: 3.0,
        mem_full_pressure_pct: 1.0
      )

      vm_metric_fixture(vm, at4(15))

      assert %{cpu_pressure_pct: 20.0, mem_pressure_pct: 2.0, mem_full_pressure_pct: 0.5} =
               summary(vm)

      older = vm_fixture(box_fixture())
      vm_metric_fixture(older, at4(5))

      assert %{cpu_pressure_pct: nil, mem_pressure_pct: nil, mem_full_pressure_pct: nil} =
               Metrics.job_summary(older, ~U[2026-11-03 10:00:00Z], ~U[2026-11-03 10:01:00Z])
    end

    test "coverage is the share of the job its samples stand for", %{vm: vm} do
      for s <- 5..60//5, do: vm_metric_fixture(vm, at4(s))
      assert %{coverage: 1.0} = summary(vm)
    end

    # A disconnected agent: samples at the start and the end of a 60 s job.
    # The rest is unknown, not idle.
    test "a gap in the samples lowers the coverage", %{vm: vm} do
      vm_metric_fixture(vm, at4(5), cpu_pct: 100.0)
      vm_metric_fixture(vm, at4(60), cpu_pct: 100.0)

      assert %{coverage: coverage} = summary(vm)
      # 5 s for the first, 15 s at most for the gap.
      assert_in_delta coverage, 20 / 60, 0.001
    end

    test "a job without both times has no coverage", %{vm: vm} do
      vm_metric_fixture(vm, at4(5))
      assert %{coverage: nil} = Metrics.job_summary(vm, nil, ~U[2026-11-03 10:01:00Z])
    end

    # 4 vCPUs busy, then 2, then 1, for 5 s each: on 1 vCPU, 3 + 1 cores'
    # worth of demand would wait for 5 s each.
    test "cpu_excess is the core-seconds of demand above each smaller vCPU count", %{vm: vm} do
      vm_metric_fixture(vm, at4(5), cpu_pct: 100.0)
      vm_metric_fixture(vm, at4(10), cpu_pct: 50.0)
      vm_metric_fixture(vm, at4(15), cpu_pct: 25.0)

      assert %{cpu_excess: [20.0, 10.0, 5.0]} = summary(vm)
    end
  end

  describe "cpu_excess/2" do
    test "weights each sample by the time since the one before, within reason" do
      # 1 s after the first, then a 60 s gap (the agent was away): the
      # gap counts as 15 s at most.
      samples = [%{t: 100, cpu_pct: 100.0}, %{t: 101, cpu_pct: 100.0}, %{t: 161, cpu_pct: 100.0}]
      # 2 cores above 2 vCPUs, for 5 + 1 + 15 s.
      assert [_, 42.0, 21.0] = Metrics.cpu_excess(samples, 4)
    end

    test "a 1-vCPU VM has no smaller count" do
      assert [] == Metrics.cpu_excess([%{t: 1, cpu_pct: 100.0}], 1)
    end

    property "never negative, never growing with more vCPUs, and 0 above the busiest sample" do
      check all(
              vcpus <- integer(1..32),
              pcts <- list_of(float(min: 0.0, max: 100.0), min_length: 1, max_length: 50),
              gaps <- list_of(integer(0..30), length: length(pcts))
            ) do
        {samples, _} =
          Enum.map_reduce(Enum.zip(pcts, gaps), 1_000, fn {p, g}, t ->
            {%{t: t + g, cpu_pct: p}, t + g}
          end)

        excess = Metrics.cpu_excess(samples, vcpus)
        assert length(excess) == vcpus - 1
        assert Enum.all?(excess, &(&1 >= 0))
        assert excess == Enum.sort(excess, :desc)

        busiest = Enum.max(pcts) / 100 * vcpus

        for {e, v} <- Enum.with_index(excess, 1), v >= busiest, do: assert(e == 0.0)

        # No more than every busy core-second there was.
        total = samples |> Enum.map(&(&1.cpu_pct / 100 * vcpus * 15)) |> Enum.sum()
        assert Enum.all?(excess, &(&1 <= total + 0.1))
      end
    end
  end
end
