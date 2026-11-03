defmodule Crew.Jobs.RunAttempt do
  @moduledoc "One attempt of a workflow run (§6.4, §22)."
  use Crew.Schema

  schema "run_attempts" do
    belongs_to :repo, Crew.Repos.Repo
    field :github_run_id, :integer
    field :run_attempt, :integer
    field :run_number, :integer
    field :workflow_name, :string
    field :event, :string
    field :head_branch, :string
    field :head_sha, :string
    field :head_commit_message, :string
    field :actor_login, :string
    field :actor_id, :integer
    field :pull_requests, {:array, :map}, default: []
    field :pr_number, :integer
    field :head_repo_full_name, :string
    field :is_fork, :boolean
    field :status, :string
    field :conclusion, :string
    field :gh_created_at, :utc_datetime_usec
    field :gh_updated_at, :utc_datetime_usec
    has_many :jobs, Crew.Jobs.Job
    timestamps()
  end

  # GitHub's run statuses, in the order a run moves through them.
  @ranks %{
    "requested" => 0,
    "waiting" => 1,
    "pending" => 1,
    "queued" => 1,
    "in_progress" => 2,
    "completed" => 3
  }

  def rank(status), do: Map.get(@ranks, status, 1)

  @pr_events ~w(pull_request pull_request_target pull_request_review pull_request_review_comment)

  @doc """
  Whether a run is a fork PR (§19.5): a pull-request event whose head
  repo is missing or isn't the repo itself.
  """
  def fork?(event, head_repo_full_name, repo_full_name) do
    event in @pr_events and
      (is_nil(head_repo_full_name) or
         String.downcase(head_repo_full_name) != String.downcase(repo_full_name))
  end
end
