defmodule Crew.Jobs.InsightsTest do
  use Crew.DataCase

  alias Crew.Jobs.{Insights, RunAttempt}
  alias Crew.Scope

  setup do
    %{
      repo: repo_fixture(name: "app"),
      admin: Scope.for_user(user_fixture(role: "admin")),
      today: Date.utc_today()
    }
  end

  defp ago(s), do: DateTime.utc_now() |> DateTime.add(-s) |> Map.put(:microsecond, {0, 6})

  # A finished Crew job: `run_s` long, after `wait_s` in the queue, done at
  # `completed_at` (an hour ago). With `sha`, its run attempt exists too.
  defp job(repo, attrs \\ []) do
    attrs = Map.new(attrs)
    completed = Map.get(attrs, :completed_at, ago(3600))
    started = DateTime.add(completed, -Map.get(attrs, :run_s, 60))
    run_id = Map.get(attrs, :run_id, System.unique_integer([:positive]))

    attempt =
      case Map.get(attrs, :sha) do
        nil ->
          nil

        sha ->
          Repo.insert!(%RunAttempt{
            repo_id: repo.id,
            github_run_id: run_id,
            run_attempt: 1,
            run_number: 1,
            workflow_name: Map.get(attrs, :workflow_name, "CI"),
            head_sha: sha,
            status: "completed",
            gh_created_at: started
          })
      end

    job_row_fixture(repo,
      workflow_name: Map.get(attrs, :workflow_name, "CI"),
      name: Map.get(attrs, :name, "test"),
      conclusion: Map.get(attrs, :conclusion, "success"),
      queued_at: DateTime.add(started, -Map.get(attrs, :wait_s, 10)),
      started_at: started,
      completed_at: completed,
      github_run_id: run_id,
      run_attempt_id: attempt && attempt.id
    )
  end

  describe "for_repo/3" do
    test "counts, pass rate, percentiles and minutes over the window", ctx do
      for {run_s, wait_s, conclusion} <- [
            {60, 10, "success"},
            {120, 20, "success"},
            {180, 30, "success"},
            {600, 40, "failure"}
          ],
          do: job(ctx.repo, run_s: run_s, wait_s: wait_s, conclusion: conclusion)

      %{totals: t} = Insights.for_repo(ctx.admin, ctx.repo, 30, ctx.today)

      assert t.jobs == 4
      assert t.success == 3
      assert t.failure == 1
      assert t.other == 0
      assert t.pass_rate == 0.75
      assert t.run_p50 == 120
      assert t.run_p95 == 600
      assert t.wait_p50 == 20
      assert t.wait_p95 == 40
      assert t.job_s == 960
      assert t.job_billable_min == 16
    end

    test "the window is the last N UTC days, today included", ctx do
      today =
        ctx.today |> DateTime.new!(~T[00:30:00], "Etc/UTC") |> Map.put(:microsecond, {0, 6})

      job(ctx.repo, name: "in-30", completed_at: DateTime.add(today, -29 * 86_400))
      job(ctx.repo, name: "out-30", completed_at: DateTime.add(today, -30 * 86_400))
      job(ctx.repo, name: "in-7", completed_at: DateTime.add(today, -6 * 86_400))

      assert %{totals: %{jobs: 2}} =
               thirty = Insights.for_repo(ctx.admin, ctx.repo, 30, ctx.today)

      assert Enum.map(thirty.jobs, & &1.name) |> Enum.sort() == ["in-30", "in-7"]
      assert length(thirty.series) == 30

      assert %{totals: %{jobs: 1}} = seven = Insights.for_repo(ctx.admin, ctx.repo, 7, ctx.today)
      assert length(seven.series) == 7
    end

    test "a job finishing just after the day the page asked for counts on that day", ctx do
      yesterday = Date.add(ctx.today, -1)

      after_midnight =
        ctx.today |> DateTime.new!(~T[00:00:01], "Etc/UTC") |> Map.put(:microsecond, {0, 6})

      job(ctx.repo, completed_at: after_midnight)

      %{totals: %{jobs: 1}, series: series} = Insights.for_repo(ctx.admin, ctx.repo, 7, yesterday)
      assert %{day: ^yesterday, success: 1} = List.last(series)
    end

    test "timed out counts as failed; cancelled and skipped as other, outside the pass rate",
         ctx do
      job(ctx.repo, conclusion: "success")
      job(ctx.repo, conclusion: "success")
      job(ctx.repo, conclusion: "timed_out")
      job(ctx.repo, conclusion: "cancelled")
      job(ctx.repo, conclusion: "skipped")

      assert %{totals: %{jobs: 5, success: 2, failure: 1, other: 2, pass_rate: rate}} =
               Insights.for_repo(ctx.admin, ctx.repo, 30, ctx.today)

      assert_in_delta rate, 2 / 3, 0.001
    end

    test "with no jobs: zeros, nils and an empty series of days", ctx do
      assert %{totals: t, series: series, jobs: [], flaky: []} =
               Insights.for_repo(ctx.admin, ctx.repo, 7, ctx.today)

      assert %{jobs: 0, pass_rate: nil, run_p50: nil, wait_p50: nil, job_s: 0} = t
      assert length(series) == 7
      assert Enum.all?(series, &(&1.success == 0 and &1.run_p50 == nil))
    end

    test "the series has each day's counts and run percentiles", ctx do
      today = ctx.today

      noon_yesterday =
        today
        |> Date.add(-1)
        |> DateTime.new!(~T[12:00:00], "Etc/UTC")
        |> Map.put(:microsecond, {0, 6})

      job(ctx.repo, completed_at: noon_yesterday, run_s: 100, conclusion: "success")
      job(ctx.repo, completed_at: noon_yesterday, run_s: 300, conclusion: "failure")

      %{series: series} = Insights.for_repo(ctx.admin, ctx.repo, 7, ctx.today)
      assert Enum.map(series, & &1.day) == Enum.map(6..0//-1, &Date.add(today, -&1))

      yesterday = Enum.find(series, &(&1.day == Date.add(today, -1)))
      assert %{success: 1, failure: 1, other: 0, run_p50: 100, run_p95: 300} = yesterday
      assert %{success: 0, failure: 0, run_p50: nil} = List.last(series)
    end

    test "jobs are grouped by workflow and name, most minutes first, with their last run", ctx do
      job(ctx.repo, name: "test", run_s: 600, conclusion: "failure", completed_at: ago(7200))

      last =
        job(ctx.repo, name: "test", run_s: 60, conclusion: "success", completed_at: ago(3600))

      job(ctx.repo, name: "lint", run_s: 30)
      job(ctx.repo, workflow_name: nil, name: "deploy", run_s: 1200)

      %{jobs: rows} = Insights.for_repo(ctx.admin, ctx.repo, 30, ctx.today)

      assert Enum.map(rows, &{&1.workflow_name, &1.name}) == [
               {nil, "deploy"},
               {"CI", "test"},
               {"CI", "lint"}
             ]

      test_row = Enum.at(rows, 1)

      assert %{runs: 2, success: 1, failure: 1, pass_rate: 0.5, run_p50: 60, run_p95: 600} =
               test_row

      assert test_row.job_s == 660
      assert test_row.last.github_id == last.github_id
      assert test_row.last.conclusion == "success"
      assert test_row.last.completed_at == last.completed_at
    end

    test "a job that failed, then passed on the same commit, is flaky", ctx do
      # Flaky: failed, re-run on the same SHA passed.
      job(ctx.repo, name: "test", sha: "aaa", conclusion: "failure", completed_at: ago(7200))
      job(ctx.repo, name: "test", sha: "aaa", conclusion: "success", completed_at: ago(3600))
      # Not flaky: failed twice on one SHA, or passed and then failed.
      job(ctx.repo, name: "build", sha: "bbb", conclusion: "failure", completed_at: ago(7200))
      job(ctx.repo, name: "build", sha: "bbb", conclusion: "failure", completed_at: ago(3600))
      job(ctx.repo, name: "lint", sha: "ccc", conclusion: "success", completed_at: ago(7200))
      job(ctx.repo, name: "lint", sha: "ccc", conclusion: "failure", completed_at: ago(3600))
      # Not flaky: a failure fixed by a new commit.
      job(ctx.repo, name: "docs", sha: "ddd", conclusion: "failure", completed_at: ago(7200))
      job(ctx.repo, name: "docs", sha: "eee", conclusion: "success", completed_at: ago(3600))
      # Failed, passed, failed again: one flake (the first); the last failure stands.
      job(ctx.repo, name: "e2e", sha: "fff", conclusion: "failure", completed_at: ago(10_800))
      job(ctx.repo, name: "e2e", sha: "fff", conclusion: "success", completed_at: ago(7200))
      job(ctx.repo, name: "e2e", sha: "fff", conclusion: "timed_out", completed_at: ago(3600))

      %{flaky: flaky, totals: totals} = Insights.for_repo(ctx.admin, ctx.repo, 30, ctx.today)

      assert [
               %{workflow_name: "CI", name: "e2e", flakes: 1, runs: 3},
               %{workflow_name: "CI", name: "test", flakes: 1, runs: 2}
             ] = flaky

      assert totals.flaky_jobs == 2
    end

    test "a member who can't read the repo gets nothing", ctx do
      job(ctx.repo)
      member = Scope.for_user(user_fixture(role: "member"))
      assert Insights.for_repo(member, ctx.repo, 30, ctx.today) == nil
    end
  end

  describe "percentile/2" do
    test "nearest rank: the smallest value at least p of the list is at or below" do
      assert Insights.percentile([5], 0.5) == 5
      assert Insights.percentile([3, 1, 2], 0.5) == 2
      assert Insights.percentile([1, 2, 3, 4], 0.5) == 2
      assert Insights.percentile([60, 600], 0.5) == 60
      assert Insights.percentile([1, 2, 3, 4], 0.95) == 4
      assert Insights.percentile(Enum.to_list(1..100), 0.95) == 95
      assert Insights.percentile([], 0.5) == nil
    end
  end
end
