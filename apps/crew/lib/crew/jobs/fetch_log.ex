defmodule Crew.Jobs.FetchLog do
  @moduledoc """
  Fetches a finished job's log from GitHub, the authoritative one
  (§16.3), at 5, 15, 60 and 180 s after `completed`: GitHub's log is often
  404 at first. If every attempt fails, the job keeps only the live
  capture (`log_source: live`). Log fetches are normal-class calls (§6.6).
  """
  use Oban.Worker,
    queue: :github,
    max_attempts: 5,
    unique: [period: 600, keys: [:job_id, :attempt]]

  require Logger

  alias Crew.{Jobs, Logs, Repos}
  alias Crew.GitHub.Client

  # Seconds after `completed` for each attempt.
  @at [5, 15, 60, 180]

  @doc "Schedules the first fetch for a job that just completed."
  def schedule(job),
    do: %{job_id: job.id, attempt: 0} |> new(schedule_in: hd(@at)) |> Oban.insert()

  @impl true
  def perform(%{args: %{"job_id" => job_id, "attempt" => attempt}}) do
    case Jobs.get_job(job_id) do
      nil ->
        :ok

      job ->
        repo = job.repo_id |> Repos.get!() |> Repos.with_installation()
        fetch(job, repo, attempt)
    end
  end

  defp fetch(job, repo, attempt) do
    inst = repo.installation.github_id
    limit = Application.get_env(:crew, :log_limit_bytes, 104_857_600)

    result =
      case Client.job_log_location(inst, repo.full_name, job.github_id) do
        {:ok, {:url, url}} ->
          Client.download_log(url, limit)

        {:ok, {:body, body}} ->
          {:ok, binary_part(body, 0, min(byte_size(body), limit)), byte_size(body) > limit}

        error ->
          error
      end

    case result do
      {:ok, body, cut?} ->
        Logs.store_github(job, body, cut?)
        Jobs.set_log_source(job, "github")
        :ok

      {:error, :not_found} when attempt < length(@at) - 1 ->
        fetch_later(job, attempt)

      {:error, :not_found} ->
        Jobs.set_log_source(job, "live")
        :ok

      {:error, {:delayed, until_ms}} ->
        # The budget holds normal calls until the reset: this same job
        # runs again then (a copy would collide with it).
        {:snooze, max(1, div(until_ms - System.os_time(:millisecond), 1000))}

      {:error, reason} ->
        Logger.warning(
          "fetching job #{job.github_id}'s log: #{inspect(reason) |> String.slice(0, 200)}"
        )

        if attempt >= length(@at) - 1,
          do: Jobs.set_log_source(job, "live"),
          else: fetch_later(job, attempt)

        :ok
    end
  rescue
    # A log that can't be stored (it shouldn't happen) leaves the live one.
    e ->
      Logger.error("storing job #{job.github_id}'s log: #{Exception.message(e)}")
      Jobs.set_log_source(job, "live")
      :ok
  end

  defp fetch_later(job, attempt) do
    wait = Enum.at(@at, attempt + 1) - Enum.at(@at, attempt)
    %{job_id: job.id, attempt: attempt + 1} |> new(schedule_in: wait) |> Oban.insert()
    :ok
  end
end
