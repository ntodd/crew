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

  describe "the critical path" do
    @starved [cpu_pressure_pct: 40.0, cpu_excess: [1800.0, 1200.0, 600.0]]

    # A run of CI with a starved 10-minute Crew job, test, and a
    # GitHub-hosted e2e that takes `e2e_s`, both queued at the start.
    defp starved_run(repo, i, e2e_s) do
      run_id = unique()
      started = hours_ago(50 - i)
      {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: run_id))

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: unique(),
            run_id: run_id,
            name: "e2e",
            labels: ["ubuntu-latest"],
            status: "completed",
            conclusion: "success",
            created_at: DateTime.to_iso8601(started),
            started_at: DateTime.to_iso8601(started),
            completed_at: DateTime.to_iso8601(DateTime.add(started, e2e_s))
          )
        )

      finished(
        repo,
        [run_id: run_id, created_at: DateTime.to_iso8601(started), started_at: started] ++
          @starved
      )
    end

    test "more vCPUs for a starved job that sets its runs' length", %{repo: repo} do
      jobs = for i <- 1..5, do: starved_run(repo, i, 60)

      assert %Hint{kind: :faster, reasons: [_, path]} = Sizing.for_job(List.last(jobs))
      assert path =~ "on its run's critical path in 5 of the 5 runs where it waited"

      assert [%{name: "test", hint: %Hint{kind: :faster}}] =
               Sizing.for_repo(Scope.for_user(user_fixture(role: "admin")), repo)
    end

    test "none for one that finishes while another job is still going", %{repo: repo} do
      jobs = for i <- 1..5, do: starved_run(repo, i, 1200)

      assert %Hint{kind: kind, reasons: reasons} = Sizing.for_job(List.last(jobs))
      refute kind == :faster

      assert Enum.any?(
               reasons,
               &(&1 =~ "off its run's critical path in 5 of the 5 runs where it waited")
             )

      assert [%{name: "test", hint: %Hint{kind: kind}}] =
               Sizing.fleet(Scope.for_user(user_fixture(role: "admin"))).hints

      refute kind == :faster
    end

    test "as before for runs Crew can't trace", %{repo: repo} do
      jobs = finished_n(repo, 5, @starved)
      assert %Hint{kind: :faster, reasons: [_]} = Sizing.for_job(List.last(jobs))
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

  describe "fleet/1" do
    defp admin, do: Scope.for_user(user_fixture(role: "admin"))

    # A run on m (8 GiB) for 600 s reserves 8 * 600 / 3600 GiB-hours.
    @run_gib_h 8 * 600 / 3600

    test "totals over 7 days: memory reserved, peak used, and what the hints would free", %{
      repo: repo
    } do
      finished_n(repo, 5)
      fleet = Sizing.fleet(admin())

      assert_in_delta fleet.reserved_gib_h, 5 * @run_gib_h, 0.001
      assert_in_delta fleet.used_gib_h, 5 * (1000 / 1024) * 600 / 3600, 0.001
      # xs instead of m: 6 of the 8 GiB, for every run.
      assert_in_delta fleet.freed_gib_h, 5 * 6 * 600 / 3600, 0.001
      assert fleet.needs_more == 0
      assert fleet.days == 7
    end

    test "older runs count toward a job's hint, but not the week's totals", %{repo: repo} do
      for i <- 1..4,
          do: finished(repo, started_at: DateTime.add(DateTime.utc_now(), -(10 + i) * 86_400))

      finished(repo)
      fleet = Sizing.fleet(admin())

      assert_in_delta fleet.reserved_gib_h, @run_gib_h, 0.001
      assert [%{name: "test", hint: %{kind: :smaller}}] = fleet.hints
      assert_in_delta fleet.freed_gib_h, 6 * 600 / 3600, 0.001
    end

    test "each repo's share, the most to free first, and each hint with its repo", %{repo: repo} do
      other = repo_fixture(name: "other")
      finished_n(repo, 5)
      finished_n(other, 5, vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7))
      fleet = Sizing.fleet(admin())

      assert [%{repo: %{id: first}, runs: 5}, %{repo: %{id: second}, runs: 5}] = fleet.repos
      assert {first, second} == {other.id, repo.id}
      assert [%{repo: %{id: ^first}}, %{repo: %{id: ^second}}] = fleet.hints
    end

    test "what the hints free and what they take are kept apart, and netted", %{repo: repo} do
      finished_n(repo, 5)
      finished(repo, name: "e2e", oom: true, conclusion: "failure")
      fleet = Sizing.fleet(admin())

      assert fleet.needs_more == 1
      assert_in_delta fleet.freed_gib_h, 5 * 6 * 600 / 3600, 0.001
      # m to l: 8 GiB more for its one run.
      assert_in_delta fleet.taken_gib_h, 8 * 600 / 3600, 0.001
      assert_in_delta fleet.net_gib_h, (5 * 6 - 8) * 600 / 3600, 0.001
      assert Enum.map(fleet.hints, & &1.name) == ["test", "e2e"]

      assert [%{freed_gib_h: freed, taken_gib_h: taken}] = fleet.repos
      assert_in_delta freed, 5 * 6 * 600 / 3600, 0.001
      assert_in_delta taken, 8 * 600 / 3600, 0.001
    end

    test "an archived repo's runs still count toward the week, but it gets no hints", %{
      repo: repo
    } do
      finished_n(repo, 5)
      Repo.update!(Ecto.Changeset.change(repo, archived_at: DateTime.utc_now()))
      fleet = Sizing.fleet(admin())

      assert_in_delta fleet.reserved_gib_h, 5 * @run_gib_h, 0.001
      assert [%{repo: %{id: id}, runs: 5}] = fleet.repos
      assert id == repo.id
      assert fleet.hints == []
    end

    test "only the repos the viewer can read", %{repo: repo} do
      finished_n(repo, 5)
      member = user_fixture()
      fleet = Sizing.fleet(Scope.for_user(member))
      assert %{repos: [], hints: [], reserved_gib_h: +0.0} = fleet

      Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      assert %{repos: [_], hints: [_]} = Sizing.fleet(Scope.for_user(member))
    end

    test "runs from before summaries kept the shape don't count", %{repo: repo} do
      finished_n(repo, 3, vcpus: nil, memory_mib: nil)
      assert %{repos: [], reserved_gib_h: +0.0} = Sizing.fleet(admin())
    end
  end

  describe "durations/1" do
    defp ran(repo, minutes, attrs) do
      started = hours_ago(attrs[:hours] || 1)

      finished(repo, [started_at: started] ++ Keyword.delete(attrs, :hours))
      |> then(fn job ->
        Repo.update_all(from(j in Crew.Jobs.Job, where: j.id == ^job.id),
          set: [completed_at: DateTime.add(started, minutes * 60)]
        )

        Repo.get!(Crew.Jobs.Job, job.id)
      end)
    end

    test "the median duration of the job's successful runs on each shape it ran on", %{
      repo: repo
    } do
      l = [vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]
      for {m, h} <- [{10, 9}, {12, 8}, {11, 7}], do: ran(repo, m, [hours: h] ++ l)
      for {m, h} <- [{9, 6}, {14, 5}], do: ran(repo, m, hours: h)
      ran(repo, 30, hours: 4, conclusion: "failure")
      newest = ran(repo, 13, hours: 3)

      assert [
               %{shape: %{name: "m", vcpus: 4, memory_mib: 8192}, runs: 3, median_s: 780},
               %{shape: %{name: "l", vcpus: 8}, runs: 3, median_s: 660}
             ] = Sizing.durations(newest)
    end

    test "a run under a second counts; one older than 90 days doesn't", %{repo: repo} do
      l = [vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]
      ran(repo, 0, [hours: 5] ++ l)
      ran(repo, 20, [hours: 91 * 24] ++ l)
      newest = ran(repo, 10, hours: 1)

      assert [%{shape: %{vcpus: 4}}, %{shape: %{vcpus: 8}, runs: 1, median_s: 0}] =
               Sizing.durations(newest)
    end

    test "nothing to compare on one shape, or for a job still running", %{repo: repo} do
      for h <- 1..3, do: ran(repo, 10, hours: h)
      assert Sizing.durations(ran(repo, 10, hours: 0)) == []

      {:ok, running} =
        Crew.Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: unique(), status: "in_progress")
        )

      assert Sizing.durations(running) == []
    end
  end
end
