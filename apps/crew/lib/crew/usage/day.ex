defmodule Crew.Usage.Day do
  @moduledoc """
  A UTC day's usage for one box, repo and VM shape (§16.6, §22). Jobs
  with no VM have no box. It keeps the shape, not the size, so editing
  or deleting a size leaves history alone.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "usage_days" do
    field :day, :date
    field :box_id, :binary_id
    field :repo_id, :binary_id
    field :vcpus, :integer
    field :memory_mib, :integer
    field :vm_count, :integer, default: 0
    field :unused_count, :integer, default: 0
    field :boot_s, :integer, default: 0
    field :idle_s, :integer, default: 0
    field :busy_s, :integer, default: 0
    field :teardown_s, :integer, default: 0
    field :vcpu_s, :integer, default: 0
    field :mem_mib_s, :integer, default: 0
    field :job_count, :integer, default: 0
    field :success_count, :integer, default: 0
    field :failure_count, :integer, default: 0
    field :job_s, :integer, default: 0
    field :job_billable_min, :integer, default: 0
  end
end
