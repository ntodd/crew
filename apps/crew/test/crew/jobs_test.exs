defmodule Crew.JobsTest do
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.Jobs
  alias Crew.Jobs.Job

  setup do
    repo = repo_fixture(name: "app")
    %{repo: repo}
  end

  defp job!(github_id), do: Repo.get_by!(Job, github_id: github_id)

  describe "workflow_job events" do
    test "a queued Crew job is ours, with its size, arch and label key", %{repo: repo} do
      payload = workflow_job_payload(repo, id: 1, labels: ["self-hosted", "crew-l-arm64"])
      assert {:ok, %Job{} = job} = Jobs.handle_workflow_job(payload)

      assert job.classification == "ours"
      assert job.gh_state == "queued"
      assert job.label_key == ["crew-l-arm64", "self-hosted"]
      assert job.arch == "arm64"
      assert Crew.Sizes.get!(job.size_id).name == "l"
      assert job.queued_at == ~U[2026-11-03 10:00:00.000000Z]
      assert job.seen_at
      assert job.repo_id == repo.id
    end

    test "a job without Crew labels isn't ours", %{repo: repo} do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["ubuntu-latest"]))
      assert job.classification == "not_ours"
      assert job.label_key == ["ubuntu-latest"]
    end

    test "bad Crew labels are unsatisfiable, with the reason", %{repo: repo} do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["crew-huge"]))
      assert job.classification == "unsatisfiable"
      assert job.unsatisfiable_reason == "unknown size huge"
    end

    test "a disabled repo's jobs aren't ours", %{repo: repo} do
      Repo.update!(Ecto.Changeset.change(repo, enabled: false))
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo))
      assert job.classification == "not_ours"
    end

    test "a size the repo doesn't allow is unsatisfiable", %{repo: repo} do
      Repo.update!(Ecto.Changeset.change(repo, allowed_sizes: ["s"]))
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["crew-m"]))
      assert job.unsatisfiable_reason == "size m not allowed for this repo"
    end

    test "a missing App permission is unsatisfiable", %{repo: _} do
      installation =
        installation_fixture(permissions: %{"actions" => "write", "metadata" => "read"})

      repo = repo_fixture(installation: installation)
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo))
      assert job.classification == "unsatisfiable"
      assert job.unsatisfiable_reason =~ "administration"
    end

    test "an aliased label set is ours, and marked", %{repo: repo} do
      admin = Crew.Scope.for_user(user_fixture(role: "admin"))

      {:ok, _} =
        Crew.Sizes.create_alias(admin, %{
          labels: ["self-hosted", "linux", "x64"],
          size_id: Crew.Sizes.default().id,
          arch: "x64"
        })

      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, labels: ["self-hosted", "linux", "x64"])
        )

      assert job.classification == "ours"
      assert job.aliased
      assert job.arch == "x64"
    end

    test "every event is recorded", %{repo: repo} do
      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 2, status: "queued"))

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 2,
            status: "in_progress",
            runner_name: "crew-ab12-m3-0123456789"
          )
        )

      job = job!(2)
      assert Enum.map(Jobs.list_events(job), & &1.kind) == ["queued", "in_progress"]
    end
  end

  describe "gh_state only moves forward (§8.2)" do
    test "an earlier state is recorded and otherwise ignored", %{repo: repo} do
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 3,
            status: "completed",
            conclusion: "success",
            completed_at: "2026-11-03T10:05:00Z",
            runner_name: "r1"
          )
        )

      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 3, status: "queued"))
      assert job.gh_state == "completed"
      assert job.conclusion == "success"
      assert job.runner_name == "r1"
      assert length(Jobs.list_events(job)) == 2
    end

    test "the first event seen may be any state", %{repo: repo} do
      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: 4, status: "in_progress", runner_name: "r2")
        )

      assert job.gh_state == "in_progress"
      assert job.started_at == ~U[2026-11-03 10:00:05.000000Z]
    end

    test "waiting is before queued", %{repo: repo} do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 5, status: "waiting"))
      assert job.gh_state == "waiting"
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 5, status: "queued"))
      assert job.gh_state == "queued"
    end

    test "completion stores the conclusion, times and steps", %{repo: repo} do
      steps = [
        %{
          "name" => "Set up job",
          "number" => 1,
          "status" => "completed",
          "conclusion" => "success",
          "started_at" => "2026-11-03T10:00:06Z",
          "completed_at" => "2026-11-03T10:00:07Z"
        }
      ]

      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 6))

      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 6,
            status: "completed",
            conclusion: "failure",
            completed_at: "2026-11-03T10:03:00Z",
            steps: steps
          )
        )

      assert job.conclusion == "failure"
      assert job.completed_at == ~U[2026-11-03 10:03:00.000000Z]
      assert [%{"name" => "Set up job"}] = job.steps
    end

    test "concurrent workers can't move a job backwards", %{repo: repo} do
      states = ~w(waiting queued in_progress completed)

      for _ <- 1..5 do
        id = unique()

        states
        |> Enum.shuffle()
        |> Enum.map(fn state ->
          Task.async(fn ->
            Jobs.handle_workflow_job(
              workflow_job_payload(repo,
                id: id,
                status: state,
                conclusion: if(state == "completed", do: "success")
              )
            )
          end)
        end)
        |> Task.await_many()

        assert job!(id).gh_state == "completed"
        assert job!(id).conclusion == "success"
      end
    end
  end

  describe "run attempts and the fork check (§19.5)" do
    test "a Crew job whose run attempt isn't known is blocked, checking fork status", %{
      repo: repo
    } do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: 70))
      assert job.blocked_reason == "checking fork status"
      assert job.run_attempt_id == nil
      # The run fetch is queued, essential.
      assert_enqueued(
        worker: Crew.Jobs.FetchRunAttempt,
        args: %{"repo_id" => repo.id, "run_id" => 70, "attempt" => 1}
      )
    end

    test "a non-Crew job isn't blocked", %{repo: repo} do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["ubuntu-latest"]))
      assert job.blocked_reason == nil
      refute_enqueued(worker: Crew.Jobs.FetchRunAttempt)
    end

    test "the run attempt links its jobs and unblocks them when it's not a fork", %{repo: repo} do
      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 8, run_id: 71))
      {:ok, attempt} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 71))

      assert attempt.is_fork == false
      assert attempt.workflow_name == "CI"
      assert attempt.head_commit_message == "Fix the thing"
      job = job!(8)
      assert job.run_attempt_id == attempt.id
      assert job.blocked_reason == nil
      assert job.classification == "ours"
    end

    test "a run attempt seen first links jobs as they arrive", %{repo: repo} do
      {:ok, attempt} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 72))
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: 72))
      assert job.run_attempt_id == attempt.id
      assert job.blocked_reason == nil
      refute_enqueued(worker: Crew.Jobs.FetchRunAttempt)
    end

    test "a fork PR on a refusing repo is unsatisfiable, and the run is cancelled", %{repo: repo} do
      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 9, run_id: 73))

      {:ok, attempt} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 73, event: "pull_request", head_repo: "stranger/app")
        )

      assert attempt.is_fork
      job = job!(9)
      assert job.classification == "unsatisfiable"
      assert job.unsatisfiable_reason == "fork PRs are refused on this repo"
      assert job.blocked_reason == nil

      assert_enqueued(
        worker: Crew.Jobs.CancelRun,
        args: %{"repo_id" => repo.id, "run_id" => 73, "attempt" => 1}
      )

      assert Enum.any?(Crew.Audit.recent(), &(&1.action == "run.fork_refused"))
    end

    test "a fork run seen before its jobs is cancelled when the first Crew job arrives", %{
      repo: repo
    } do
      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 76, event: "pull_request", head_repo: "stranger/app")
        )

      refute_enqueued(worker: Crew.Jobs.CancelRun)

      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: 76))
      assert job.unsatisfiable_reason == "fork PRs are refused on this repo"

      assert_enqueued(
        worker: Crew.Jobs.CancelRun,
        args: %{"repo_id" => repo.id, "run_id" => 76, "attempt" => 1}
      )

      assert Enum.count(Crew.Audit.recent(), &(&1.action == "run.fork_refused")) == 1

      # More jobs of the same run don't cancel or audit it again.
      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: 76))
      assert length(all_enqueued(worker: Crew.Jobs.CancelRun)) == 1
      assert Enum.count(Crew.Audit.recent(), &(&1.action == "run.fork_refused")) == 1
    end

    test "a null head repo on a PR event counts as a fork", %{repo: repo} do
      {:ok, attempt} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, event: "pull_request_target", head_repo: nil)
        )

      assert attempt.is_fork
    end

    test "a fork PR on a repo that allows them runs", %{repo: repo} do
      Repo.update!(Ecto.Changeset.change(repo, fork_prs: "allow"))

      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 74, event: "pull_request", head_repo: "stranger/app")
        )

      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: 74))
      assert job.classification == "ours"
      refute_enqueued(worker: Crew.Jobs.CancelRun)
    end

    test "a push from a fork-named branch isn't a fork: only PR events count", %{repo: repo} do
      {:ok, attempt} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, event: "push", head_repo: "stranger/app")
        )

      refute attempt.is_fork
    end

    test "run attempts only move forward too", %{repo: repo} do
      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo,
            id: 75,
            action: "completed",
            status: "completed",
            conclusion: "success"
          )
        )

      {:ok, attempt} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 75, action: "in_progress", status: "in_progress")
        )

      assert attempt.status == "completed"
      assert attempt.conclusion == "success"
    end
  end

  describe "reclassifying (§7.4)" do
    test "settings changes re-parse jobs GitHub still has queued or waiting", %{repo: repo} do
      {:ok, queued} = Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["crew-xl"]))

      {:ok, done} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            labels: ["crew-xl"],
            status: "completed",
            conclusion: "success"
          )
        )

      assert queued.classification == "ours"

      Repo.update!(Ecto.Changeset.change(repo, allowed_sizes: ["s"]))
      :ok = Jobs.reclassify_open(repo_id: repo.id)

      assert Repo.reload!(queued).unsatisfiable_reason == "size xl not allowed for this repo"
      assert Repo.reload!(done).classification == "ours"
    end
  end

  test "changes are broadcast with ids only", %{repo: repo} do
    Phoenix.PubSub.subscribe(Crew.PubSub, "jobs")
    {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo))
    assert_received {:job_changed, id} when id == job.id
  end

  test "a webhook marks its repo active, at most every 30 s", %{repo: repo} do
    {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo))
    first = Crew.Repos.get!(repo.id).last_activity_at
    assert first
    {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo))
    assert Crew.Repos.get!(repo.id).last_activity_at == first
  end

  test "an event for an unknown repo of a known installation adds the repo", %{repo: repo} do
    other = %{repo | github_id: unique(), full_name: "acme/brand-new"}
    {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(other))
    assert Crew.Repos.get_by_full_name("acme/brand-new").id == job.repo_id
  end

  describe "list_runs search (§17.3)" do
    setup %{repo: repo} do
      for {id, attrs} <- [
            {901, head_branch: "main", actor: "mona"},
            {902, head_branch: "Feature/Login", actor: "hubot"},
            {903,
             head_branch: "fix-718", actor: "dependabot[bot]", pull_requests: [%{"number" => 42}]},
            {904, head_branch: "release/v2", actor: "mona", pull_requests: [%{"number" => 718}]}
          ] do
        {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, [id: id] ++ attrs))
      end

      %{scope: Crew.Scope.for_user(user_fixture(role: "admin"))}
    end

    defp search(scope, filters),
      do: scope |> Jobs.list_runs(filters) |> Enum.map(& &1.github_run_id) |> Enum.sort()

    test "a term matches part of a branch or an actor, any case", %{scope: scope} do
      assert search(scope, %{"q" => "login"}) == [902]
      assert search(scope, %{"q" => "MONA"}) == [901, 904]
      assert search(scope, %{"q" => "bot"}) == [902, 903]
    end

    test "a number matches a PR, and also branches and actors containing it", %{scope: scope} do
      assert search(scope, %{"q" => "718"}) == [903, 904]
      assert search(scope, %{"q" => "#718"}) == [904]
    end

    test "every term has to match", %{scope: scope} do
      assert search(scope, %{"q" => "mona release"}) == [904]
      assert search(scope, %{"q" => "  mona   main "}) == [901]
    end

    test "branch:, pr: and actor: match that field exactly", %{scope: scope} do
      assert search(scope, %{"q" => "branch:main"}) == [901]
      assert search(scope, %{"q" => "branch:mai"}) == []
      assert search(scope, %{"q" => "actor:Mona"}) == [901, 904]
      assert search(scope, %{"q" => "actor:dependabot[bot]"}) == [903]
      assert search(scope, %{"q" => "pr:42"}) == [903]
    end

    test "LIKE wildcards and the escape character are matched literally", %{
      scope: scope,
      repo: repo
    } do
      for {id, branch} <- [{905, "fix_bug"}, {906, "fixAbug"}, {907, "wow!"}] do
        {:ok, _} =
          Jobs.handle_workflow_run(workflow_run_payload(repo, id: id, head_branch: branch))
      end

      assert search(scope, %{"q" => "%"}) == []
      assert search(scope, %{"q" => "fix_b"}) == [905]
      assert search(scope, %{"q" => "w!"}) == [907]
    end

    test "a number too big for a PR doesn't fail the search", %{scope: scope, repo: repo} do
      big = "92233720368547758080"

      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 908, head_branch: "fix-#{big}-2147483648")
        )

      assert search(scope, %{"q" => big}) == [908]
      assert search(scope, %{"q" => "2147483648"}) == [908]
      assert search(scope, %{"q" => "#" <> big}) == []
      assert search(scope, %{"q" => "pr:" <> big}) == []
      assert search(scope, %{"q" => "#2147483648"}) == []

      {:ok, _} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 910, pull_requests: [%{"number" => 2_147_483_647}])
        )

      assert search(scope, %{"q" => "#2147483647"}) == [910]
    end

    test "a branch with non-ASCII capitals is found by its own spelling", %{
      scope: scope,
      repo: repo
    } do
      {:ok, _} =
        Jobs.handle_workflow_run(workflow_run_payload(repo, id: 909, head_branch: "Fix-École"))

      assert search(scope, %{"q" => "École"}) == [909]
      assert search(scope, %{"q" => "fix-É"}) == [909]
    end

    test "a qualifier still being typed doesn't filter", %{scope: scope} do
      assert search(scope, %{"q" => "branch: mona"}) == [901, 904]
      assert search(scope, %{"q" => "#"}) == [901, 902, 903, 904]
    end

    test "a blank search matches everything", %{scope: scope} do
      assert search(scope, %{"q" => "   "}) == [901, 902, 903, 904]
    end
  end

  describe "list_runs with crew" do
    setup %{repo: repo} do
      for {run_id, labels} <- [{911, ["crew-m"]}, {912, ["ubuntu-latest"]}, {913, ["crew-huge"]}] do
        {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: run_id))

        {:ok, _} =
          Jobs.handle_workflow_job(workflow_job_payload(repo, run_id: run_id, labels: labels))
      end

      # A run with no jobs seen yet.
      {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 914))

      %{scope: Crew.Scope.for_user(user_fixture(role: "admin"))}
    end

    test "keeps only runs with a job for Crew, runnable or not", %{scope: scope} do
      assert scope |> Jobs.list_runs(%{"crew" => "true"}) |> Enum.map(& &1.github_run_id) ==
               [913, 911]

      assert length(Jobs.list_runs(scope, %{})) == 4
    end
  end

  describe "list_attempts" do
    test "every attempt of a run, oldest first, for whoever may read it", %{repo: repo} do
      for {n, status, conclusion} <- [
            {1, "completed", "failure"},
            {2, "completed", "cancelled"},
            {3, "in_progress", nil}
          ] do
        {:ok, _} =
          Jobs.handle_workflow_run(
            workflow_run_payload(repo,
              id: 930,
              run_attempt: n,
              status: status,
              conclusion: conclusion
            )
          )
      end

      admin = Crew.Scope.for_user(user_fixture(role: "admin"))

      assert [
               %{run_attempt: 1, conclusion: "failure"},
               %{run_attempt: 2, conclusion: "cancelled"},
               %{run_attempt: 3, status: "in_progress"}
             ] = Jobs.list_attempts(admin, 930)

      assert Jobs.list_attempts(Crew.Scope.for_user(user_fixture()), 930) == []
    end
  end
end
