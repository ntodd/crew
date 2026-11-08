defmodule Crew.Metrics do
  @moduledoc """
  Box, VM and job metrics (§16.5, Foreman's). Samples are stored in Unix
  seconds and kept for 7 days (§9.4).
  """
  import Ecto.Query

  alias Crew.Metrics.{BoxMetric, VMMetric}
  alias Crew.Repo

  @keep_days 7

  @doc "Stores a `box.metrics` sample (its `t` is Unix milliseconds)."
  def record_box(box_id, m) do
    Repo.insert_all(BoxMetric, [
      %{
        box_id: box_id,
        t: div(m.t, 1000),
        cpu_pct: m.cpu_pct * 1.0,
        mem_used_mib: m.mem_used_mib,
        mem_total_mib: m.mem_total_mib,
        swap_used_mib: m.swap_used_mib,
        load1: m.load1 * 1.0,
        disk_used_mib: m.disk_used_mib,
        disk_total_mib: m.disk_total_mib,
        vm_area_free_mib: m.vm_area_free_mib,
        cache_used_mib: m.cache_used_mib,
        vms_running: m.vms_running
      }
    ])

    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{box_id}", {:box_metrics, box_id})
    :ok
  end

  def latest_box(box_id) do
    Repo.one(from m in BoxMetric, where: m.box_id == ^box_id, order_by: [desc: m.t], limit: 1)
  end

  @doc "A box's samples since `since` (Unix seconds), oldest first."
  def box_series(box_id, since) do
    Repo.all(from m in BoxMetric, where: m.box_id == ^box_id and m.t >= ^since, order_by: m.t)
  end

  @doc """
  A box's samples since `since`, averaged over `step`-second buckets,
  oldest first: CPU, memory used (and the total), and load. A point's `t`
  is its bucket's start, or `since` for the first.
  """
  def box_series(box_id, since, step) do
    from(m in BoxMetric,
      where: m.box_id == ^box_id and m.t >= ^since,
      group_by: fragment("bucket"),
      order_by: fragment("bucket"),
      select: %{
        t: fragment("? - (? % ?) AS bucket", m.t, m.t, ^step),
        cpu_pct: type(avg(m.cpu_pct), :float),
        mem_used_mib: type(avg(m.mem_used_mib), :float),
        mem_total_mib: max(m.mem_total_mib),
        load1: type(avg(m.load1), :float)
      }
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{p | t: max(p.t, since), mem_used_mib: round(p.mem_used_mib)}
    end)
  end

  @doc "Stores a `vm.metrics` sample for `vm` (its `t` is Unix milliseconds)."
  def record_vm(vm, m) do
    Repo.insert_all(VMMetric, [
      %{
        vm_id: vm.id,
        box_id: vm.box_id,
        job_id: vm.job_id,
        t: div(m.t, 1000),
        cpu_pct: m.cpu_pct * 1.0,
        mem_used_mib: m.mem_used_mib,
        mem_total_mib: m.mem_total_mib,
        disk_used_mib: m.disk_used_mib,
        net_rx_bps: m.net_rx_bps * 1.0,
        net_tx_bps: m.net_tx_bps * 1.0,
        host_cpu_pct: m.host_cpu_pct * 1.0,
        host_rss_mib: m.host_rss_mib,
        mem_peak_mib: m[:mem_peak_mib],
        oom_kills: m[:oom_kills],
        cpu_pressure_pct: float(m[:cpu_pressure_pct]),
        mem_pressure_pct: float(m[:mem_pressure_pct]),
        mem_full_pressure_pct: float(m[:mem_full_pressure_pct])
      }
    ])

    Phoenix.PubSub.broadcast(Crew.PubSub, Crew.Logs.topic(vm.id), {:vm_metrics, vm.id})
    :ok
  end

  defp float(nil), do: nil
  defp float(n), do: n * 1.0

  @doc "A VM's samples, oldest first."
  def vm_series(vm_id), do: Repo.all(from m in VMMetric, where: m.vm_id == ^vm_id, order_by: m.t)

  # A sample's `t` is when the agent sent the guest's latest reading, up
  # to one interval after the guest took it, and the reading covers the
  # interval before that. So the window keeps samples up to two intervals
  # past the finish: a trailing idle one only lowers average CPU, and a
  # dropped one could hide the job's last peak.
  @slack_s 10

  # A sample stands for the time since the one before it: 5 s for the
  # first, and at most 15 s, so a gap while the agent was away doesn't
  # count as one long busy stretch (and lowers the coverage instead).
  @first_s 5
  @longest_s 15

  @doc """
  A finished job's resource summary (§16.5) from the samples of `vm` (its
  `id`, `vcpus` and `memory_mib`) while the job ran, from `started_at` to
  `completed_at`. The VM's boot and the runner's wait for the job don't
  count. A job too short for a sample of its own, or without both times,
  gets every sample of its VM.

  Besides the peaks and averages it keeps what right-sizing needs once
  the samples are pruned (§7.5): the shape the job ran on, whether the
  kernel killed anything for memory while it ran, the average stall
  pressure, and `cpu_excess/2`.
  """
  def job_summary(vm, started_at, completed_at) do
    all = vm_series(vm.id)

    case while_running(all, started_at, completed_at) do
      [] -> nil
      samples -> summarize(samples, before(all, samples), vm, started_at, completed_at)
    end
  end

  defp while_running(samples, %DateTime{} = from, %DateTime{} = until) do
    {a, b} = {DateTime.to_unix(from), DateTime.to_unix(until) + @slack_s}

    case Enum.filter(samples, &(&1.t >= a and &1.t <= b)) do
      [] -> samples
      kept -> kept
    end
  end

  defp while_running(samples, _from, _until), do: samples

  # The last sample before the job's: its OOM count is where the job's starts.
  defp before(all, [first | _]), do: all |> Enum.take_while(&(&1 != first)) |> List.last()

  defp summarize(samples, before, vm, started_at, completed_at) do
    net =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> (a.net_rx_bps + a.net_tx_bps) / 8 * max(b.t - a.t, 0) end)
      |> Enum.sum()

    %{
      peak_mem_mib:
        samples |> Enum.map(&max(&1.mem_used_mib, &1.mem_peak_mib || 0)) |> Enum.max(),
      peak_cpu_pct: Enum.max_by(samples, & &1.cpu_pct).cpu_pct,
      avg_cpu_pct: Float.round(Enum.sum_by(samples, & &1.cpu_pct) / length(samples), 1),
      peak_disk_mib: Enum.max_by(samples, & &1.disk_used_mib).disk_used_mib,
      net_bytes: round(net),
      vcpus: vm.vcpus,
      memory_mib: vm.memory_mib,
      oom: oom?(samples, before),
      cpu_pressure_pct: mean(samples, & &1.cpu_pressure_pct),
      mem_pressure_pct: mean(samples, & &1.mem_pressure_pct),
      mem_full_pressure_pct: mean(samples, & &1.mem_full_pressure_pct),
      cpu_excess: cpu_excess(samples, vm.vcpus),
      coverage: coverage(samples, started_at, completed_at)
    }
  end

  # The share of the job its samples stand for, weighted as `cpu_excess/2`
  # weights them: a gap while the agent was away is unknown, not idle.
  defp coverage(samples, %DateTime{} = from, %DateTime{} = until) do
    covered = samples |> weights() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    Float.round(min(covered / max(DateTime.diff(until, from), @first_s), 1.0), 3)
  end

  defp coverage(_samples, _from, _until), do: nil

  # The guest's count is since boot: the job's kills are its rise.
  defp oom?(samples, before) do
    case samples |> Enum.map(& &1.oom_kills) |> Enum.reject(&is_nil/1) do
      [] -> false
      counts -> Enum.max(counts) > ((before && before.oom_kills) || 0)
    end
  end

  defp mean(samples, fun) do
    case samples |> Enum.map(fun) |> Enum.reject(&is_nil/1) do
      [] -> nil
      xs -> Float.round(Enum.sum(xs) / length(xs), 2)
    end
  end

  @doc """
  For each vCPU count from 1 to one fewer than `vcpus`, the core-seconds
  of demand above it: the work that would have waited on that many
  vCPUs (§7.5). Demand is a sample's CPU share of the VM's `vcpus`.
  Samples can't see demand above the VM's own vCPUs, so the estimate is
  only ever for smaller counts.
  """
  def cpu_excess(samples, vcpus) when vcpus > 1 do
    weighted = weights(samples)

    for v <- 1..(vcpus - 1) do
      weighted
      |> Enum.map(fn {s, dt} -> max(s.cpu_pct / 100 * vcpus - v, 0) * dt end)
      |> Enum.sum()
      |> Kernel.*(1.0)
      |> Float.round(1)
    end
  end

  def cpu_excess(_samples, _vcpus), do: []

  @doc """
  Each sample (oldest first, with `t` in Unix seconds) with the seconds
  it stands for: 5 s for the first, then the gap since the one before,
  at most 15 s.
  """
  def weights(samples) do
    samples
    |> Enum.map_reduce(nil, fn s, prev ->
      dt = if prev, do: min(max(s.t - prev, 0), @longest_s), else: @first_s
      {{s, dt}, s.t}
    end)
    |> elem(0)
  end

  @doc "Drops samples older than #{@keep_days} days."
  def prune(now \\ System.os_time(:second)) do
    cutoff = now - @keep_days * 86_400
    Repo.delete_all(from m in BoxMetric, where: m.t < ^cutoff)
    Repo.delete_all(from m in VMMetric, where: m.t < ^cutoff)
    Crew.Caches.prune(cutoff)
    :ok
  end
end
