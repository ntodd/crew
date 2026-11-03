defmodule Crew.Scheduler.ClassState do
  @moduledoc "Per class (repo, label key): failures and backoff, stalls, and how long it's had excess (§8.5, §8.6)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "class_state" do
    field :repo_id, :binary_id, primary_key: true
    field :class_hash, :string, primary_key: true
    field :class_key, {:array, :string}
    field :consecutive_failures, :integer, default: 0
    field :last_error, :string
    field :backoff_until, :utc_datetime_usec
    field :stalled_until, :utc_datetime_usec
    field :stall_count, :integer, default: 0
    field :idle_max_reaps, :integer, default: 0
    field :excess_since, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
