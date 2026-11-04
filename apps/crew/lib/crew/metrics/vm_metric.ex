defmodule Crew.Metrics.VMMetric do
  @moduledoc "One 5 s sample of a VM (§16.5): the guest's view and the host's, `t` in Unix seconds."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "vm_metrics" do
    field :vm_id, :binary_id
    field :box_id, :binary_id
    field :job_id, :binary_id
    field :t, :integer
    field :cpu_pct, :float, default: 0.0
    field :mem_used_mib, :integer, default: 0
    field :mem_total_mib, :integer, default: 0
    field :disk_used_mib, :integer, default: 0
    field :net_rx_bps, :float, default: 0.0
    field :net_tx_bps, :float, default: 0.0
    field :host_cpu_pct, :float, default: 0.0
    field :host_rss_mib, :integer, default: 0
  end
end
