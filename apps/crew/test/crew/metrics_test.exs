defmodule Crew.MetricsTest do
  @moduledoc "Reading box samples back for charts (§16.5)."
  use Crew.DataCase

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
               Metrics.job_summary(vm.id, @start, @finish)
    end

    # The agent stamps a guest reading when it sends it, up to one
    # interval after the guest took it, and the reading covers the
    # interval before that: a sample up to two intervals past the finish
    # can still hold the job's last seconds.
    test "keeps the samples that can still hold the job's last seconds", %{vm: vm} do
      vm_metric_fixture(vm, at(30), mem_used_mib: 1000)
      vm_metric_fixture(vm, at(70), mem_used_mib: 4000)

      assert %{peak_mem_mib: 4000} = Metrics.job_summary(vm.id, @start, @finish)
    end

    # Times are whole seconds, so a sample in the job's first second is
    # stamped with its start.
    test "keeps a sample stamped with the job's start", %{vm: vm} do
      vm_metric_fixture(vm, at(0), mem_used_mib: 5000)
      vm_metric_fixture(vm, at(5), mem_used_mib: 1000)

      assert %{peak_mem_mib: 5000} = Metrics.job_summary(vm.id, @start, @finish)
    end

    test "a job shorter than one sample gets every sample of its VM", %{vm: vm} do
      vm_metric_fixture(vm, at(-5), cpu_pct: 20.0, mem_used_mib: 500)
      vm_metric_fixture(vm, at(20), cpu_pct: 40.0, mem_used_mib: 700)

      assert %{peak_mem_mib: 700, avg_cpu_pct: 30.0} =
               Metrics.job_summary(vm.id, @start, DateTime.add(@start, 1))
    end

    test "without both times, every sample counts", %{vm: vm} do
      vm_metric_fixture(vm, at(-5), cpu_pct: 20.0)
      vm_metric_fixture(vm, at(10), cpu_pct: 40.0)

      assert %{avg_cpu_pct: 30.0} = Metrics.job_summary(vm.id, nil, @finish)
      assert %{avg_cpu_pct: 30.0} = Metrics.job_summary(vm.id, @start, nil)
    end

    test "a VM with no samples has no summary", %{vm: vm} do
      assert nil == Metrics.job_summary(vm.id, @start, @finish)
    end
  end
end
