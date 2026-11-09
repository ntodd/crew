defmodule Crew.Jobs.Insights do
  @moduledoc """
  A repo's CI over its last `days` UTC days, today included (§17.3): how
  many Crew jobs ran and passed, how long they ran and waited in the
  queue (p50 and p95), their minutes, each day's counts, every job's own
  numbers, and the flaky ones.

  Read from `jobs` rather than the usage rollup, so job names are known.
  A job counts when it ran on Crew: classified ours, completed, with a
  start and a runner. Its day is the UTC day it completed.

  A job **failed** when GitHub concluded `failure`, `timed_out` or
  `startup_failure`; `cancelled`, `skipped` and the rest are *other*, and
  don't count toward the pass rate. A job is **flaky** on a commit when it
  failed there and a later run of it on the same commit passed, within
  the window. A failure fixed by a new commit isn't flaky; neither is a
  pass followed by a failure.
  """
  import Ecto.Query

  alias Crew.{Repo, Repos, Scope}
  alias Crew.Jobs.{Job, RunAttempt}
  alias Crew.Repos.Repo, as: GitRepo
  alias Crew.Usage.Tally

  @type totals :: %{
          jobs: non_neg_integer(),
          success: non_neg_integer(),
          failure: non_neg_integer(),
          other: non_neg_integer(),
          pass_rate: float() | nil,
          run_p50: non_neg_integer() | nil,
          run_p95: non_neg_integer() | nil,
          wait_p50: non_neg_integer() | nil,
          wait_p95: non_neg_integer() | nil,
          job_s: non_neg_integer(),
          job_billable_min: non_neg_integer()
        }

  @doc """
  The repo's insights over `days`, or nil for a scope that can't read it.

  `totals` covers the window; `series` has one entry per UTC day, oldest
  first; `jobs` has one row per `(workflow_name, name)`, most minutes
  first, each with its `last` run; `flaky` lists the flaky jobs, most
  flakes first. `totals.flaky_jobs` counts them.
  """
  def for_repo(%Scope{} = scope, %GitRepo{} = repo, days, today \\ Date.utc_today())
      when days > 0 do
    if Repos.can_read?(scope, repo.id) do
      from = Date.add(today, 1 - days)
      jobs = load(repo.id, DateTime.new!(from, ~T[00:00:00], "Etc/UTC"))
      flaky = flaky(jobs)

      %{
        from: from,
        to: today,
        days: days,
        totals: jobs |> totals() |> Map.put(:flaky_jobs, length(flaky)),
        series: series(jobs, from, today),
        jobs: by_job(jobs),
        flaky: flaky
      }
    end
  end

  @doc """
  Nearest-rank percentile: the smallest value that at least `p` of the
  list is at or below, so p50 of two values is the lower one. Nil for none.
  """
  def percentile([], _p), do: nil

  def percentile(xs, p) do
    sorted = Enum.sort(xs)
    Enum.at(sorted, max(ceil(p * length(sorted)) - 1, 0))
  end

  defp load(repo_id, since) do
    Repo.all(
      from j in Job,
        left_join: a in RunAttempt,
        on: a.id == j.run_attempt_id,
        where:
          j.repo_id == ^repo_id and j.classification == "ours" and j.gh_state == "completed" and
            not is_nil(j.started_at) and not is_nil(j.completed_at) and
            not is_nil(j.runner_name) and j.runner_name != "" and
            j.completed_at >= ^since,
        select: %{
          github_id: j.github_id,
          github_run_id: j.github_run_id,
          run_attempt: j.run_attempt,
          workflow_name: j.workflow_name,
          name: j.name,
          conclusion: j.conclusion,
          queued_at: j.queued_at,
          seen_at: j.seen_at,
          started_at: j.started_at,
          completed_at: j.completed_at,
          head_sha: a.head_sha
        }
    )
  end

  defp totals(jobs) do
    runs = run_durations(jobs)
    waits = durations(jobs, &(&1.queued_at || &1.seen_at), & &1.started_at)
    tally = jobs |> Enum.map(&Tally.job/1) |> Tally.add()
    success = Enum.count(jobs, &passed?/1)
    failure = Enum.count(jobs, &failed?/1)

    %{
      jobs: length(jobs),
      success: success,
      failure: failure,
      other: length(jobs) - success - failure,
      pass_rate: rate(success, failure),
      run_p50: percentile(runs, 0.5),
      run_p95: percentile(runs, 0.95),
      wait_p50: percentile(waits, 0.5),
      wait_p95: percentile(waits, 0.95),
      job_s: Map.get(tally, :job_s, 0),
      job_billable_min: Map.get(tally, :job_billable_min, 0)
    }
  end

  # A job finishing in the minutes after `to` was fixed (midnight passing
  # under the page, or GitHub's clock ahead of Crew's) counts on `to`, so
  # the series adds up to the totals.
  defp series(jobs, from, to) do
    by_day = Enum.group_by(jobs, &Enum.min([DateTime.to_date(&1.completed_at), to], Date))

    for day <- Date.range(from, to) do
      day_jobs = Map.get(by_day, day, [])
      runs = run_durations(day_jobs)
      success = Enum.count(day_jobs, &passed?/1)
      failure = Enum.count(day_jobs, &failed?/1)

      %{
        day: day,
        success: success,
        failure: failure,
        other: length(day_jobs) - success - failure,
        run_p50: percentile(runs, 0.5),
        run_p95: percentile(runs, 0.95)
      }
    end
  end

  defp by_job(jobs) do
    jobs
    |> Enum.group_by(&{&1.workflow_name, &1.name})
    |> Enum.map(fn {{workflow, name}, group} ->
      last = Enum.max_by(group, & &1.completed_at, DateTime)

      group
      |> totals()
      |> Map.merge(%{
        workflow_name: workflow,
        name: name,
        runs: length(group),
        last: ref(last)
      })
      |> Map.delete(:jobs)
    end)
    |> Enum.sort_by(&{-&1.job_s, &1.workflow_name || "", &1.name || ""})
  end

  defp flaky(jobs) do
    jobs
    |> Enum.filter(& &1.head_sha)
    |> Enum.group_by(&{&1.workflow_name, &1.name, &1.head_sha})
    |> Enum.flat_map(fn {{workflow, name, _sha}, group} -> flakes(workflow, name, group) end)
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {{workflow, name}, flakes} ->
      last = Enum.max_by(flakes, & &1.completed_at, DateTime)

      %{
        workflow_name: workflow,
        name: name,
        flakes: length(flakes),
        runs: Enum.count(jobs, &(&1.workflow_name == workflow and &1.name == name)),
        last: ref(last)
      }
    end)
    |> Enum.sort_by(&{-&1.flakes, &1.workflow_name || "", &1.name || ""})
  end

  # The failures on one commit that a later run of the same job passed.
  defp flakes(workflow, name, group) do
    group
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.reduce({[], false}, fn job, {acc, passed_later?} ->
      cond do
        passed?(job) -> {acc, true}
        failed?(job) and passed_later? -> {[Map.put(job, :key, {workflow, name}) | acc], true}
        true -> {acc, passed_later?}
      end
    end)
    |> elem(0)
  end

  defp ref(job),
    do: Map.take(job, [:github_id, :github_run_id, :run_attempt, :conclusion, :completed_at])

  defp run_durations(jobs), do: durations(jobs, & &1.started_at, & &1.completed_at)

  defp durations(jobs, from, to) do
    for j <- jobs, a = from.(j), b = to.(j), a && b, d = DateTime.diff(b, a), d >= 0, do: d
  end

  defp passed?(%{conclusion: "success"}), do: true
  defp passed?(_job), do: false

  defp failed?(%{conclusion: c}), do: c in ~w(failure timed_out startup_failure)

  defp rate(0, 0), do: nil
  defp rate(success, failure), do: success / (success + failure)
end
