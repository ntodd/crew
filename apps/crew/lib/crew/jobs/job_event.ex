defmodule Crew.Jobs.JobEvent do
  @moduledoc "Something that happened to a job, from GitHub, the API, the guest or the scheduler."
  use Crew.Schema

  schema "job_events" do
    belongs_to :job, Crew.Jobs.Job
    field :source, :string
    field :kind, :string
    field :payload, :map
    field :at, :utc_datetime_usec
  end
end
