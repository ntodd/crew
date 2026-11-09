defmodule Crew.Jobs.PruneTest do
  @moduledoc """
  Job retention (§9.4): jobs, run attempts and VM rows, with their
  events, after 90 days, but never before the usage rollup has stored
  their day (§16.6).
  """
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.Jobs.{Job, JobEvent, Prune, RunAttempt}
  alias Crew.Metrics.VMMetric
  alias Crew.Usage
  alias Crew.Usage.{Day, RolledDay}
  alias Crew.VMs.{VM, VMEvent}

  setup do
    on_exit(fn ->
      Application.delete_env(:crew, :job_retention_days)
      Application.delete_env(:crew, :job_prune_batch)
    end)

    %{repo: repo_fixture(), box: box_fixture()}
  end

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -round(days * 86_400))

  # Every closed day stored, as it is once the rollup has caught up.
  defp rolled_up(_context) do
    today = Date.utc_today()
    now = DateTime.utc_now()
    days = for d <- 1..200, do: %{day: Date.add(today, -d), computed_at: now}
    Repo.insert_all(RolledDay, days)
    :ok
  end

  defp attempt_fixture(repo, updated_at) do
    Repo.insert!(%RunAttempt{
      repo_id: repo.id,
      github_run_id: unique(),
      run_attempt: 1,
      inserted_at: updated_at,
      updated_at: updated_at
    })
  end

  defp count(query), do: Repo.aggregate(query, :count)

  describe "with every day rolled up" do
    setup :rolled_up

    test "jobs that finished before the retention go, with their events", %{repo: repo} do
      old = job_row_fixture(repo, completed_at: ago(91))
      Repo.insert!(%JobEvent{job_id: old.id, source: "webhook", kind: "completed", at: ago(91)})
      recent = job_row_fixture(repo, completed_at: ago(89))

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(Job, old.id)
      assert count(from e in JobEvent, where: e.job_id == ^old.id) == 0
      assert Repo.get(Job, recent.id)
    end

    test "a job that never finished goes once nothing has been heard of it for the retention",
         %{repo: repo} do
      stuck =
        job_row_fixture(repo,
          gh_state: "queued",
          conclusion: nil,
          seen_at: ago(100),
          last_event_at: ago(91)
        )

      waiting =
        job_row_fixture(repo,
          gh_state: "queued",
          conclusion: nil,
          seen_at: ago(100),
          last_event_at: ago(1)
        )

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(Job, stuck.id)
      assert Repo.get(Job, waiting.id)
    end

    test "destroyed VMs go with their events and samples; one that isn't destroyed stays",
         %{box: box} do
      gone = vm_fixture(box, state: "destroyed", requested_at: ago(92), destroyed_at: ago(91))
      Repo.insert!(%VMEvent{vm_id: gone.id, kind: "destroyed", at: ago(91)})
      vm_metric_fixture(gone, DateTime.to_unix(ago(91)))
      recent = vm_fixture(box, state: "destroyed", requested_at: ago(90), destroyed_at: ago(89))
      live = vm_fixture(box, state: "failed", requested_at: ago(120), failed_at: ago(119))

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(VM, gone.id)
      assert count(from e in VMEvent, where: e.vm_id == ^gone.id) == 0
      assert count(from m in VMMetric, where: m.vm_id == ^gone.id) == 0
      assert Repo.get(VM, recent.id)
      assert Repo.get(VM, live.id)
    end

    test "a VM stays while a job that's kept ran on it", %{repo: repo, box: box} do
      kept = vm_fixture(box, state: "destroyed", requested_at: ago(92), destroyed_at: ago(91))
      job_row_fixture(repo, vm_id: kept.id, completed_at: ago(89))
      gone = vm_fixture(box, state: "destroyed", requested_at: ago(92), destroyed_at: ago(91))
      job_row_fixture(repo, vm_id: gone.id, completed_at: ago(91))

      assert :ok = perform_job(Prune, %{})
      assert Repo.get(VM, kept.id)
      refute Repo.get(VM, gone.id)
    end

    test "a run attempt goes with its jobs, once every one of them is past the retention",
         %{repo: repo} do
      done = attempt_fixture(repo, ago(91))
      old = job_row_fixture(repo, run_attempt_id: done.id, completed_at: ago(92))
      Repo.insert!(%JobEvent{job_id: old.id, source: "webhook", kind: "completed", at: ago(92)})
      job_row_fixture(repo, run_attempt_id: done.id, completed_at: ago(91))

      # One job still kept keeps the whole run, so its page shows every job.
      open = attempt_fixture(repo, ago(91))
      older = job_row_fixture(repo, run_attempt_id: open.id, completed_at: ago(91))
      job_row_fixture(repo, run_attempt_id: open.id, gh_state: "waiting", last_event_at: ago(1))

      changed = attempt_fixture(repo, ago(1))
      job_row_fixture(repo, run_attempt_id: changed.id, completed_at: ago(91))

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(RunAttempt, done.id)
      assert count(from j in Job, where: j.run_attempt_id == ^done.id) == 0
      assert count(from e in JobEvent, where: e.job_id == ^old.id) == 0
      assert Repo.get(RunAttempt, open.id)
      assert Repo.get(Job, older.id)
      assert count(from j in Job, where: j.run_attempt_id == ^changed.id) == 1
    end

    test "a run attempt with no jobs goes once it hasn't changed for the retention",
         %{repo: repo} do
      empty = attempt_fixture(repo, ago(91))
      new = attempt_fixture(repo, ago(1))

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(RunAttempt, empty.id)
      assert Repo.get(RunAttempt, new.id)
    end

    test "CREW_JOB_RETENTION_DAYS sets the retention", %{repo: repo} do
      Application.put_env(:crew, :job_retention_days, 30)
      old = job_row_fixture(repo, completed_at: ago(31))
      recent = job_row_fixture(repo, completed_at: ago(29))

      assert :ok = perform_job(Prune, %{})
      refute Repo.get(Job, old.id)
      assert Repo.get(Job, recent.id)
    end

    test "a backlog bigger than a batch goes in one run", %{repo: repo, box: box} do
      Application.put_env(:crew, :job_prune_batch, 2)

      for _ <- 1..5 do
        attempt = attempt_fixture(repo, ago(91))
        job_row_fixture(repo, run_attempt_id: attempt.id, completed_at: ago(91))
        job_row_fixture(repo, completed_at: ago(91))
        vm_fixture(box, state: "destroyed", requested_at: ago(92), destroyed_at: ago(91))
      end

      recent = job_row_fixture(repo, completed_at: ago(89))

      assert :ok = perform_job(Prune, %{})
      assert Repo.all(from j in Job, select: j.id) == [recent.id]
      assert count(RunAttempt) == 0
      assert count(VM) == 0
    end

    test "nothing goes from the days the rollup recomputes, whatever the retention",
         %{repo: repo} do
      Application.put_env(:crew, :job_retention_days, 1)
      # Yesterday or the day before, which every rollup counts again.
      recent = job_row_fixture(repo, completed_at: ago(1.5))
      old = job_row_fixture(repo, completed_at: ago(3.5))

      assert :ok = perform_job(Prune, %{})
      assert Repo.get(Job, recent.id)
      refute Repo.get(Job, old.id)
    end
  end

  test "nothing goes until the rollup has stored every day", %{repo: repo, box: box} do
    day = Date.add(Date.utc_today(), -100)
    vm = ran_fixture(box, repo, day, 600)
    later = ran_fixture(box, repo, Date.add(day, 40), 600)

    assert :ok = perform_job(Prune, %{})
    assert Repo.get(VM, vm.id)

    # The first run stores its day, but not the 60 after it: pruning it
    # now would move where the rollup fills in from past them.
    :ok = Usage.roll_up()
    assert :ok = perform_job(Prune, %{})
    assert Repo.get(VM, vm.id)

    # 31 days a run: caught up after the fourth.
    for _ <- 1..3, do: :ok = Usage.roll_up()
    assert :ok = perform_job(Prune, %{})
    refute Repo.get(VM, vm.id)
    assert Repo.get(VM, later.id)
    assert count(Job) == 1

    assert [%{vm_count: 1, job_count: 1, busy_s: 600}] =
             Repo.all(from d in Day, where: d.day == ^day)
  end
end
