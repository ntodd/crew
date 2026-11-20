defmodule Crew.VMs.VM do
  @moduledoc "A single-use job VM (§8.6, §22). It holds its box's allocation until destroyed."
  use Crew.Schema

  schema "vms" do
    belongs_to :box, Crew.Boxes.Box
    field :name, :string
    belongs_to :repo, Crew.Repos.Repo
    field :class_key, {:array, :string}
    field :class_hash, :string
    # The tier it was placed for (§7.2), whatever job it takes.
    field :spare, :boolean, default: false
    belongs_to :size, Crew.Sizes.Size
    field :vcpus, :integer
    field :memory_mib, :integer
    field :disk_gib, :integer
    field :vmm_overhead_mib, :integer, default: 0
    field :image_id, :binary_id
    field :lease_index, :integer
    field :start_op_id, :binary_id
    field :state, :string, default: "requested"
    field :fail_reason, :string
    field :job_id, :binary_id
    field :runner_id, :integer
    field :deadline, :utc_datetime_usec
    field :log_epoch, :string
    field :last_log_seq, :integer, default: 0
    field :last_log_n, :integer, default: 0
    field :log_bytes, :integer, default: 0
    field :alive, :boolean, default: false
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :booted_at, :utc_datetime_usec
    field :idle_at, :utc_datetime_usec
    field :busy_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :destroyed_at, :utc_datetime_usec
    field :stop_sent_at, :utc_datetime_usec
    field :runner_delete_since, :utc_datetime_usec
    timestamps()
  end

  @doc "A class key's stable hash, for indexing."
  def class_hash(key),
    do:
      :crypto.hash(:sha256, Enum.join(key, "\n"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)
end
