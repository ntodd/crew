defmodule Crew.Usage.BoxDay do
  @moduledoc """
  A box's UTC day (§16.6, §22): how long it was online by its samples
  (nil once they're pruned), and what it offered job VMs when the day
  was rolled up.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "usage_box_days" do
    field :day, :date
    field :box_id, :binary_id
    field :online_s, :integer
    field :allocatable_vcpus, :float
    field :allocatable_memory_mib, :integer
  end
end
