defmodule Crew.VMs.DeleteRunner do
  @moduledoc """
  Deletes a runner when nothing waits on the answer (a failed VM's, a
  late JIT's). Retried every 30 s; past that it's left to
  `Crew.GitHub.RunnerGC` (§6.3).
  """
  use Oban.Worker,
    queue: :github,
    max_attempts: 30,
    unique: [period: 900, keys: [:repo_id, :runner_id]]

  alias Crew.Repos
  alias Crew.GitHub.Client

  @impl true
  def perform(%{args: %{"repo_id" => repo_id, "runner_id" => runner_id}}) do
    repo = repo_id |> Repos.get!() |> Repos.with_installation()

    case Client.delete_runner(repo.installation.github_id, repo.full_name, runner_id) do
      # :busy (422): the runner took a job. A JIT runner removes itself
      # once that's done, and the VM links the job (§8.6).
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def backoff(_job), do: 30
end
