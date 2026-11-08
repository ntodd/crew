defmodule Crew.SizingTest do
  @moduledoc "Right-sizing hints (§7.5) from a job's stored runs and its repo's sizes."
  use Crew.DataCase

  alias Crew.{Jobs, Scope, Sizing}
  alias Crew.Sizing.Rules.Hint

  setup do
    %{repo: repo_fixture(name: "app")}
  end

  defp finished(repo, attrs \\ []), do: summarized_job_fixture(repo, attrs)
  defp finished_n(repo, n, attrs \\ []), do: summarized_jobs_fixture(repo, n, attrs)

  defp hours_ago(h),
    do: DateTime.utc_now() |> DateTime.add(-h * 3600) |> DateTime.truncate(:second)

  describe "for_job/1" do
    test "a finished job's hint, from its latest runs", %{repo: repo} do
      jobs = finished_n(repo, 5)
      assert %Hint{kind: :smaller, to: %{name: "xs"}, runs: 5} = Sizing.for_job(List.last(jobs))
      assert %Hint{kind: :smaller} = Sizing.for_job(hd(jobs))
    end

    test "only the sizes the repo may use, and none that are retired", %{repo: repo} do
      jobs = finished_n(repo, 5)
      Repo.update!(Ecto.Changeset.change(repo, allowed_sizes: ["s", "m", "xs"]))
      xs = Repo.get_by!(Crew.Sizes.Size, name: "xs")
      Repo.update!(Ecto.Changeset.change(xs, retired_at: DateTime.utc_now()))

      assert %Hint{kind: :smaller, to: %{name: "s"}} = Sizing.for_job(List.last(jobs))
    end

    test "other jobs, workflows and repos don't count", %{repo: repo} do
      job = finished(repo)
      finished_n(repo, 5, name: "lint")
      finished_n(repo, 5, workflow_name: "Release")
      finished_n(repo_fixture(name: "other"), 5)

      assert Sizing.for_job(job) == nil
    end

    test "nothing for a job that's still running, or isn't Crew's", %{repo: repo} do
      finished_n(repo, 5)

      {:ok, running} =
        Jobs.handle_workflow_job(workflow_job_payload(repo, id: unique(), status: "in_progress"))

      assert Sizing.for_job(running) == nil

      {:ok, theirs} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: unique(), status: "completed", labels: ["ubuntu-latest"])
        )

      assert Sizing.for_job(theirs) == nil
    end

    test "jobs from before the summary kept these, with nil fields, don't count", %{repo: repo} do
      jobs = finished_n(repo, 5, vcpus: nil, memory_mib: nil, cpu_excess: nil, coverage: nil)
      assert Sizing.for_job(List.last(jobs)) == nil
    end

    test "a run killed for memory asks for more, whatever came before", %{repo: repo} do
      finished_n(repo, 5)

      oom =
        finished(repo, started_at: ~U[2026-11-04 10:00:00Z], oom: true, conclusion: "failure")

      assert %Hint{kind: :larger, to: %{name: "l"}} = Sizing.for_job(oom)
    end
  end

  describe "for_repo/2" do
    setup %{repo: repo} do
      finished_n(repo, 5)
      finished_n(repo, 5, name: "e2e", peak_mem_mib: 5000)

      finished_n(repo, 5,
        name: "build",
        vcpus: 8,
        memory_mib: 16_384,
        cpu_excess: List.duplicate(0.0, 7)
      )

      :ok
    end

    test "each job with a change to suggest, the most memory freed first", %{repo: repo} do
      admin = Scope.for_user(user_fixture(role: "admin"))

      assert [
               %{
                 name: "build",
                 workflow_name: "CI",
                 hint: %Hint{kind: :smaller, saved_mib: 14_336},
                 job: %{github_id: _, github_run_id: _}
               },
               %{name: "test", hint: %Hint{kind: :smaller, saved_mib: 6144}}
             ] = Sizing.for_repo(admin, repo)
    end

    test "a job's history is its 30 newest runs, as on the job page", %{repo: repo} do
      # 5 runs on m, then 30 on l, then the newest back on m: the 30 newest
      # hold one run on m, too few for a hint.
      m_runs = for i <- 1..5, do: finished(repo, name: "flip", started_at: hours_ago(100 - i))

      l = [name: "flip", vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]
      for i <- 1..30, do: finished(repo, [started_at: hours_ago(60 - i)] ++ l)
      newest = finished(repo, name: "flip", started_at: hours_ago(1))

      assert Sizing.for_job(newest) == nil

      refute Enum.any?(
               Sizing.for_repo(Scope.for_user(user_fixture(role: "admin")), repo),
               &(&1.name == "flip")
             )

      assert length(m_runs) == 5
    end

    test "nothing for someone who can't read the repo", %{repo: repo} do
      stranger = Scope.for_user(user_fixture())
      assert Sizing.for_repo(stranger, repo) == []
    end
  end
end
