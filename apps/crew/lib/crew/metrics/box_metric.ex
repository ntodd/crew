defmodule Crew.Metrics.BoxMetric do
  @moduledoc "One 5 s sample of a box (§10.4), with `t` in Unix seconds (§22)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "box_metrics" do
    field :box_id, :binary_id
    field :t, :integer
    field :cpu_pct, :float
    field :mem_used_mib, :integer
    field :mem_total_mib, :integer
    field :swap_used_mib, :integer, default: 0
    field :load1, :float, default: 0.0
    field :disk_used_mib, :integer
    field :disk_total_mib, :integer
    field :vm_area_free_mib, :integer
    field :cache_used_mib, :integer, default: 0
    field :vms_running, :integer, default: 0
  end
end
