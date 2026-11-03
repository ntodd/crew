defmodule Crew.Jobs.CancelRun do
  @moduledoc "Cancels a run Crew refused (a fork PR on a repo that refuses them, §19.5)."
  use Oban.Worker,
    queue: :github,
    max_attempts: 10,
    unique: [period: 3600, keys: [:repo_id, :run_id, :attempt]]

  alias Crew.Repos
  alias Crew.GitHub.Client

  @impl true
  def perform(%{args: %{"repo_id" => repo_id, "run_id" => run_id}}) do
    # Cancelling cancels the run's current attempt; `attempt` only keeps a
    # re-run's refusal from being taken for a duplicate.
    repo = repo_id |> Repos.get!() |> Repos.with_installation()
    Client.cancel_run(repo.installation.github_id, repo.full_name, run_id)
  end
end
