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
        host_rss_mib: m.host_rss_mib
      }
    ])

    Phoenix.PubSub.broadcast(Crew.PubSub, Crew.Logs.topic(vm.id), {:vm_metrics, vm.id})
    :ok
  end

  @doc "A VM's samples, oldest first."
  def vm_series(vm_id), do: Repo.all(from m in VMMetric, where: m.vm_id == ^vm_id, order_by: m.t)

  # A sample's `t` is when the agent sent the guest's latest reading, up
  # to one interval after the guest took it, and the reading covers the
  # interval before that. So the window keeps samples up to two intervals
  # past the finish: a trailing idle one only lowers average CPU, and a
  # dropped one could hide the job's last peak.
  @slack_s 10

  @doc """
  A finished job's resource summary (§16.5): peak memory, peak and average
  CPU, peak disk and network bytes, from its VM's samples while it ran,
  from `started_at` to `completed_at`. The VM's boot and the runner's wait
  for the job don't count. A job too short for a sample of its own, or
  without both times, gets every sample of its VM.
  """
  def job_summary(vm_id, started_at, completed_at) do
    case vm_id |> vm_series() |> while_running(started_at, completed_at) do
      [] -> nil
      samples -> summarize(samples)
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

  defp summarize(samples) do
    net =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> (a.net_rx_bps + a.net_tx_bps) / 8 * max(b.t - a.t, 0) end)
      |> Enum.sum()

    %{
      peak_mem_mib: Enum.max_by(samples, & &1.mem_used_mib).mem_used_mib,
      peak_cpu_pct: Enum.max_by(samples, & &1.cpu_pct).cpu_pct,
      avg_cpu_pct: Float.round(Enum.sum_by(samples, & &1.cpu_pct) / length(samples), 1),
      peak_disk_mib: Enum.max_by(samples, & &1.disk_used_mib).disk_used_mib,
      net_bytes: round(net)
    }
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
