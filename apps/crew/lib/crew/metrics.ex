defmodule Crew.Metrics do
  @moduledoc """
  Box, VM and job metrics (§16.5, Foreman's). Samples are stored in Unix
  seconds and kept for 7 days (§9.4).
  """
  import Ecto.Query

  alias Crew.Metrics.BoxMetric
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

  @doc "Drops samples older than #{@keep_days} days."
  def prune(now \\ System.os_time(:second)) do
    cutoff = now - @keep_days * 86_400
    Repo.delete_all(from m in BoxMetric, where: m.t < ^cutoff)
    :ok
  end
end
