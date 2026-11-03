defmodule Crew.Jobs.FetchRunAttempt do
  @moduledoc """
  Fetches a run attempt that a job arrived before (§6.5). It's essential:
  it drives the fork check, and the job stays blocked until it answers,
  so a failure fails closed and is retried.
  """
  use Oban.Worker,
    queue: :github,
    max_attempts: 20,
    unique: [period: 600, keys: [:repo_id, :run_id, :attempt]]

  alias Crew.{Jobs, Repos}
  alias Crew.GitHub.Client

  @impl true
  def perform(%{args: %{"repo_id" => repo_id, "run_id" => run_id, "attempt" => attempt}}) do
    repo = repo_id |> Repos.get!() |> Repos.with_installation()

    case Client.get_run_attempt(repo.installation.github_id, repo.full_name, run_id, attempt) do
      {:ok, run} ->
        {:ok, _} = Jobs.upsert_run_attempt(repo, run)
        :ok

      {:error, {:delayed, until_ms}} ->
        {:snooze, max(1, div(until_ms - System.os_time(:millisecond), 1000))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def backoff(%{attempt: n}), do: min(300, trunc(:math.pow(2, n)))
end
