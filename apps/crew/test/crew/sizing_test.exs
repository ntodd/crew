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

    test "each hint has its newest run's workflow file, when Crew knows it", %{repo: repo} do
      finished_n(repo, 4, name: "lint")

      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 5151, path: ".github/workflows/lint.yml")
        )

      finished(repo, name: "lint", run_id: 5151)
      hints = Sizing.for_repo(Scope.for_user(user_fixture(role: "admin")), repo)

      assert %{workflow_path: ".github/workflows/lint.yml"} =
               Enum.find(hints, &(&1.name == "lint"))

      assert %{workflow_path: nil} = Enum.find(hints, &(&1.name == "test"))
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

  describe "dismissals" do
    alias Crew.Sizing.Dismissal

    setup %{repo: repo} do
      %{newest: repo |> finished_n(5) |> List.last()}
    end

    # What a page's dismiss form sends for the hint it shows.
    defp shown(job, reason \\ nil), do: shown_hint(Sizing.for_job(job), reason)

    defp shown_hint(%Hint{kind: kind, from: from}, reason),
      do: %{
        "kind" => to_string(kind),
        "vcpus" => to_string(from.vcpus),
        "memory_mib" => to_string(from.memory_mib),
        "reason" => reason
      }

    defp logged(action) do
      import Ecto.Query
      Repo.all(from e in Crew.Audit.Event, where: e.action == ^action)
    end

    test "an admin dismisses a hint: it stays on the repo, marked, and leaves the fleet's totals",
         %{repo: repo, newest: newest} do
      admin = admin()

      {:ok, %Dismissal{} = d} =
        Sizing.dismiss(admin, newest.id, shown(newest, "  xs made the tests flaky "))

      assert {d.workflow_name, d.job_name, d.kind} == {"CI", "test", "smaller"}
      assert {d.vcpus, d.memory_mib} == {4, 8192}
      assert d.reason == "xs made the tests flaky"
      assert d.user_login == admin.user.login

      assert [%{name: "test", dismissal: %Dismissal{id: id}}] = Sizing.for_repo(admin, repo)
      assert id == d.id

      fleet = Sizing.fleet(admin)
      assert fleet.hints == []
      assert [%{name: "test", repo: %{id: repo_id}, dismissal: %Dismissal{}}] = fleet.dismissed
      assert repo_id == repo.id
      assert fleet.freed_gib_h == 0.0
      assert [%{net_gib_h: +0.0}] = fleet.repos

      assert [%{metadata: %{"repo" => _, "job" => "CI · test", "kind" => "smaller"}}] =
               logged("sizing_hint.dismiss")
    end

    test "a blank reason is none, and dismissing again keeps one with the newer reason", %{
      newest: newest
    } do
      {:ok, first} = Sizing.dismiss(admin(), newest.id, shown(newest, "  "))
      assert first.reason == nil
      {:ok, again} = Sizing.dismiss(admin(), newest.id, shown(newest, "on second thought"))
      assert again.id == first.id
      assert Repo.get!(Dismissal, first.id).reason == "on second thought"
    end

    test "it's for the job's size and the kind of hint, so a new kind brings it back", %{
      repo: repo,
      newest: newest
    } do
      {:ok, _} = Sizing.dismiss(admin(), newest.id, shown(newest))
      assert [%{dismissal: %Dismissal{}}] = Sizing.for_repo(admin(), repo)

      finished(repo, oom: true, conclusion: "failure", started_at: hours_ago(1))
      assert [%{hint: %Hint{kind: :larger}, dismissal: nil}] = Sizing.for_repo(admin(), repo)
      assert [%{name: "test"}] = Sizing.fleet(admin()).hints
    end

    test "and a new size brings it back", %{repo: repo, newest: newest} do
      {:ok, _} = Sizing.dismiss(admin(), newest.id, shown(newest))

      l = [vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]
      for i <- 1..5, do: finished(repo, [started_at: hours_ago(6 - i)] ++ l)

      assert [%{hint: %Hint{kind: :smaller, from: %{vcpus: 8}}, dismissal: nil}] =
               Sizing.for_repo(admin(), repo)
    end

    test "restoring puts it back; both are logged", %{repo: repo, newest: newest} do
      {:ok, d} = Sizing.dismiss(admin(), newest.id, shown(newest))
      {:ok, _} = Sizing.restore(admin(), d.id)

      assert [%{dismissal: nil}] = Sizing.for_repo(admin(), repo)
      assert [_] = Sizing.fleet(admin()).hints
      assert [%{metadata: %{"job" => "CI · test"}}] = logged("sizing_hint.restore")
      assert Sizing.restore(admin(), d.id) == {:error, :not_found}
    end

    test "only admins dismiss and restore", %{newest: newest} do
      member = Scope.for_user(user_fixture())
      assert Sizing.dismiss(member, newest.id, shown(newest)) == {:error, :unauthorized}

      {:ok, d} = Sizing.dismiss(admin(), newest.id, shown(newest))
      assert Sizing.restore(member, d.id) == {:error, :unauthorized}
      assert logged("sizing_hint.restore") == []
    end

    test "nothing to dismiss when the job's hint isn't the one shown, or the job isn't there", %{
      repo: repo
    } do
      fits = repo |> finished_n(5, name: "e2e", peak_mem_mib: 5000) |> List.last()
      smaller = shown(List.last(finished_n(repo, 5, name: "lint")))
      assert Sizing.dismiss(admin(), fits.id, smaller) == {:error, :changed}
      assert Sizing.dismiss(admin(), Ecto.UUID.generate(), smaller) == {:error, :not_found}
    end

    test "a form left open while the hint changed dismisses nothing", %{
      repo: repo,
      newest: newest
    } do
      form = shown(newest)
      finished(repo, oom: true, conclusion: "failure", started_at: hours_ago(1))

      assert Sizing.dismiss(admin(), newest.id, form) == {:error, :changed}
      assert [%{hint: %Hint{kind: :larger}, dismissal: nil}] = Sizing.for_repo(admin(), repo)
      assert Repo.aggregate(Dismissal, :count) == 0
    end

    test "the hint a list shows, from the last 30 days, can be dismissed", %{
      repo: repo,
      newest: newest
    } do
      # Killed for memory 31 days ago: the job's page still counts that
      # run, the lists don't.
      finished(repo, oom: true, conclusion: "failure", started_at: hours_ago(31 * 24))
      assert %Hint{kind: :larger} = Sizing.for_job(newest)
      [%{hint: listed}] = Sizing.for_repo(admin(), repo)
      assert listed.kind == :smaller

      assert {:ok, _} = Sizing.dismiss(admin(), newest.id, shown_hint(listed, nil))
      assert [%{dismissal: %Dismissal{kind: "smaller"}}] = Sizing.for_repo(admin(), repo)
    end

    test "a job without a workflow name has its hint, and it can be dismissed", %{repo: repo} do
      nameless = repo |> finished_n(5, name: "solo", workflow_name: nil) |> List.last()
      assert %Hint{kind: :smaller} = Sizing.for_job(nameless)

      assert {:ok, %Dismissal{workflow_name: ""}} =
               Sizing.dismiss(admin(), nameless.id, shown(nameless))

      assert Enum.find(Sizing.for_repo(admin(), repo), &(&1.name == "solo")).dismissal
    end

    test "dismissal/2: a job's hint's dismissal, for its page", %{newest: newest} do
      hint = Sizing.for_job(newest)
      assert Sizing.dismissal(newest, hint) == nil
      {:ok, d} = Sizing.dismiss(admin(), newest.id, shown(newest, "flaky"))
      assert %Dismissal{reason: "flaky"} = Sizing.dismissal(newest, hint)
      assert Sizing.dismissal(newest, nil) == nil
      assert d.id == Sizing.dismissal(newest, hint).id
    end
  end

  describe "custom shapes" do
    @busy [cpu_excess: [1200.0, 600.0, 120.0]]

    defp add_size(name),
      do: Crew.Sizes.create(admin(), %{name: name, vcpus: 4, memory_mib: 2048, disk_gib: 20})

    test "a custom hint is a smaller one once its shape is a size the repo may use", %{repo: repo} do
      finished_n(repo, 5, [name: "build"] ++ @busy)

      assert [%{hint: %Hint{kind: :custom, to: %{vcpus: 4, memory_mib: 2048}}}] =
               Sizing.for_repo(admin(), repo)

      {:ok, _} = add_size("c4")

      assert [%{hint: %Hint{kind: :smaller, to: %{name: "c4"}, saved_mib: 6144}}] =
               Sizing.for_repo(admin(), repo)
    end

    test "not while the repo's sizes leave it out", %{repo: repo} do
      finished_n(repo, 5, [name: "build"] ++ @busy)
      {:ok, repo} = Crew.Repos.update_settings(admin(), repo, %{"allowed_sizes" => ["m", "l"]})
      {:ok, _} = add_size("c4")

      assert [%{hint: %Hint{kind: :custom}}] = Sizing.for_repo(admin(), repo)

      {:ok, repo} =
        Crew.Repos.update_settings(admin(), repo, %{"allowed_sizes" => ["m", "l", "c4"]})

      assert [%{hint: %Hint{kind: :smaller, to: %{name: "c4"}}}] = Sizing.for_repo(admin(), repo)
    end

    test "the fleet groups custom hints by the shape they'd fit, the most freed first", %{
      repo: repo
    } do
      other = repo_fixture(name: "api")
      finished_n(repo, 5, [name: "build"] ++ @busy)
      finished_n(other, 5, [name: "build"] ++ @busy)
      finished_n(other, 5, name: "pack", cpu_excess: [1200.0, 600.0, 120.0], peak_mem_mib: 2600)
      finished_n(repo, 5)

      fleet = Sizing.fleet(admin())

      assert [
               %{shape: %{vcpus: 4, memory_mib: 2048, disk_gib: 20}, hints: [_, _]} = two,
               %{shape: %{vcpus: 4, memory_mib: 4096}, hints: [%{name: "pack"}]}
             ] = fleet.custom

      assert Enum.sort(Enum.map(two.hints, & &1.repo.id)) == Enum.sort([repo.id, other.id])
      assert_in_delta two.freed_gib_h, Enum.sum(Enum.map(two.hints, & &1.freed_gib_h)), 0.001
      assert two.freed_gib_h > 0
    end

    test "a dismissed custom hint isn't in a group", %{repo: repo} do
      newest = repo |> finished_n(5, [name: "build"] ++ @busy) |> List.last()
      %Hint{kind: kind, from: from} = Sizing.for_job(newest)

      {:ok, _} =
        Sizing.dismiss(admin(), newest.id, %{
          "kind" => to_string(kind),
          "vcpus" => to_string(from.vcpus),
          "memory_mib" => to_string(from.memory_mib)
        })

      assert Sizing.fleet(admin()).custom == []
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
