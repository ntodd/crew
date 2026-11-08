defmodule Crew.Jobs.Job do
  @moduledoc """
  A GitHub `workflow_job`: one job, or one matrix leg, of one run attempt
  (§8.2). `classification` (Crew's) and `gh_state` (GitHub's) are
  independent: capacity problems block a job, they never make it
  unsatisfiable.
  """
  use Crew.Schema

  @states ~w(waiting queued in_progress completed)
  @ranks %{"waiting" => 0, "queued" => 1, "in_progress" => 2, "completed" => 3}

  schema "jobs" do
    belongs_to :repo, Crew.Repos.Repo
    belongs_to :run_attempt_record, Crew.Jobs.RunAttempt, foreign_key: :run_attempt_id
    field :github_id, :integer
    field :github_run_id, :integer
    field :run_attempt, :integer
    field :name, :string
    field :workflow_name, :string
    field :labels, {:array, :string}, default: []
    field :label_key, {:array, :string}
    belongs_to :size, Crew.Sizes.Size
    field :arch, :string
    field :aliased, :boolean, default: false
    field :classification, :string
    field :unsatisfiable_reason, :string
    field :gh_state, :string
    field :gh_state_rank, :integer, default: 0
    field :blocked_reason, :string
    field :wait_reason, :string
    field :conclusion, :string
    field :runner_name, :string
    field :vm_id, :binary_id
    field :taken_cross_class, :boolean, default: false
    field :queued_at, :utc_datetime_usec
    field :seen_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_event_at, :utc_datetime_usec
    field :checked_at, :utc_datetime_usec
    field :steps, {:array, :map}, default: []
    field :log_source, :string
    field :peak_mem_mib, :integer
    field :peak_cpu_pct, :float
    field :avg_cpu_pct, :float
    field :peak_disk_mib, :integer
    field :net_bytes, :integer
    field :oom, :boolean, default: false
    # For right-sizing (§7.5): the VM's shape, the average stall pressure,
    # the core-seconds of demand above each smaller vCPU count, and the
    # share of the job the samples cover (nil until the summary is final).
    field :vcpus, :integer
    field :memory_mib, :integer
    field :cpu_pressure_pct, :float
    field :mem_pressure_pct, :float
    field :mem_full_pressure_pct, :float
    field :cpu_excess, {:array, :float}
    field :coverage, :float
    timestamps()
  end

  def states, do: @states
  def rank(state), do: Map.fetch!(@ranks, state)
  def state?(state), do: Map.has_key?(@ranks, state)
end
