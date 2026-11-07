defmodule Crew.ReconcilerTest do
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.{GitHubStub, Jobs, Reconciler}

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: pem
    })

    on_exit(fn -> Application.delete_env(:crew, :github_app) end)
    Crew.GitHub.InstallationTokens.clear()
    Crew.GitHub.Budget.reset()
    repo = repo_fixture(name: "app")
    %{repo: repo, inst: repo.installation.github_id}
  end

  defp age_job(job, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds)
    Repo.update!(Ecto.Changeset.change(job, last_event_at: at))
  end

  defp token(inst),
    do: %{
      {"POST", "/app/installations/#{inst}/access_tokens"} =>
        {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}}
    }

  describe "queued jobs" do
    test "are re-checked 90 s after their last event, one call per run attempt", %{
      repo: repo,
      inst: inst
    } do
      {:ok, a} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 1, run_id: 50))
      {:ok, b} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 2, run_id: 50))
      {:ok, fresh} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 3, run_id: 51))
      age_job(a, 100)
      age_job(b, 100)

      Repo.update!(
        Ecto.Changeset.change(Crew.Repos.get!(repo.id),
          last_activity_at: DateTime.add(DateTime.utc_now(), -600)
        )
      )

      pid = self()

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/50/attempts/1/jobs"} => fn conn ->
            send(pid, :listed)

            GitHubStub.json(conn, 200, %{
              "jobs" => [
                %{
                  workflow_job_payload(repo, id: 1, run_id: 50)["workflow_job"]
                  | "status" => "completed",
                    "conclusion" => "cancelled"
                },
                workflow_job_payload(repo, id: 2, run_id: 50)["workflow_job"]
              ]
            })
          end
        })
      )

      assert :ok = Reconciler.check_queued()
      assert_received :listed
      refute_received :listed

      assert Jobs.get_job!(a.id).gh_state == "completed"
      assert Jobs.get_job!(b.id).checked_at
      assert Jobs.get_job!(fresh.id).checked_at == nil
    end

    test "a second check is skipped while webhooks for the repo and the job are flowing",
         %{repo: repo, inst: inst} do
      {:ok, a} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 4, run_id: 52))
      now = DateTime.utc_now()

      a =
        Repo.update!(
          Ecto.Changeset.change(a,
            checked_at: DateTime.add(now, -400),
            last_event_at: DateTime.add(now, -200)
          )
        )

      Repo.update!(
        Ecto.Changeset.change(Crew.Repos.get!(repo.id), last_activity_at: DateTime.add(now, -60))
      )

      GitHubStub.stub(%{})
      assert :ok = Reconciler.check_queued()
      assert DateTime.compare(Jobs.get_job!(a.id).checked_at, DateTime.add(now, -399)) == :lt

      # Once the repo's webhooks go quiet, it's checked.
      Repo.update!(
        Ecto.Changeset.change(Crew.Repos.get!(repo.id), last_activity_at: DateTime.add(now, -400))
      )

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/52/attempts/1/jobs"} =>
            {200, %{"jobs" => []}}
        })
      )

      assert :ok = Reconciler.check_queued()
      assert DateTime.compare(Jobs.get_job!(a.id).checked_at, DateTime.add(now, -10)) == :gt
    end

    test "after a check, the next is 5 minutes later", %{repo: repo, inst: inst} do
      {:ok, a} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 5, run_id: 53))
      age_job(a, 100)

      Repo.update!(
        Ecto.Changeset.change(Jobs.get_job!(a.id),
          checked_at: DateTime.add(DateTime.utc_now(), -120)
        )
      )

      GitHubStub.stub(token(inst))
      assert :ok = Reconciler.check_queued()
      assert DateTime.diff(DateTime.utc_now(), Jobs.get_job!(a.id).checked_at) >= 119
    end
  end

  describe "busy VMs (§8.8)" do
    setup %{repo: repo} do
      box = box_fixture(name: "m4")
      size = Repo.get_by!(Crew.Sizes.Size, name: "m")
      %{box: box, size: size, repo: repo}
    end

    defp busy_vm(box, repo, size, job) do
      id = CrewProtocol.uuid7()

      Repo.insert!(%Crew.VMs.VM{
        id: id,
        box_id: box.id,
        name: CrewProtocol.Names.runner_name("abcd", box.name, id),
        repo_id: repo.id,
        class_key: ["crew-m"],
        class_hash: Crew.VMs.VM.class_hash(["crew-m"]),
        size_id: size.id,
        vcpus: 4,
        memory_mib: 8192,
        disk_gib: 60,
        state: "busy",
        job_id: job.id,
        deadline: DateTime.add(DateTime.utc_now(), 3600),
        requested_at: DateTime.utc_now()
      })
    end

    test "a busy VM's job with no event for 15 minutes is re-checked", %{
      repo: repo,
      inst: inst,
      box: box,
      size: size
    } do
      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: 70, run_id: 60, status: "in_progress")
        )

      busy_vm(box, repo, size, job)
      age_job(job, 16 * 60)
      pid = self()

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/60/attempts/1/jobs"} => fn conn ->
            send(pid, :listed)

            GitHubStub.json(conn, 200, %{
              "jobs" => [
                %{
                  workflow_job_payload(repo, id: 70, run_id: 60)["workflow_job"]
                  | "status" => "completed",
                    "conclusion" => "success"
                }
              ]
            })
          end
        })
      )

      assert :ok = Reconciler.check_queued()
      assert_received :listed
      assert Jobs.get_job!(job.id).gh_state == "completed"
    end

    test "a busy VM's job with a recent event, or checked lately, is left alone", %{
      repo: repo,
      box: box,
      size: size
    } do
      {:ok, fresh} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: 71, run_id: 61, status: "in_progress")
        )

      busy_vm(box, repo, size, fresh)
      age_job(fresh, 10 * 60)

      {:ok, checked} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: 72, run_id: 62, status: "in_progress")
        )

      busy_vm(box, repo, size, checked)
      checked = age_job(checked, 20 * 60)

      Repo.update!(
        Ecto.Changeset.change(checked, checked_at: DateTime.add(DateTime.utc_now(), -60))
      )

      GitHubStub.stub(%{})
      assert :ok = Reconciler.check_queued()
      assert Jobs.get_job!(fresh.id).checked_at == nil
    end
  end

  describe "stale jobs (§8.8)" do
    defp hosted_job(repo, attrs) do
      payload = workflow_job_payload(repo, [labels: ["ubuntu-latest"]] ++ attrs)
      {:ok, job} = Jobs.handle_workflow_job(payload)
      assert job.classification == "not_ours"
      job
    end

    defp listed(repo, attrs),
      do: workflow_job_payload(repo, [labels: ["ubuntu-latest"]] ++ attrs)["workflow_job"]

    test "an unfinished job Crew doesn't run, with no event for an hour, is re-checked", %{
      repo: repo,
      inst: inst
    } do
      running = hosted_job(repo, id: 80, run_id: 70, status: "in_progress")
      queued = hosted_job(repo, id: 81, run_id: 70)
      age_job(running, 61 * 60)
      age_job(queued, 61 * 60)
      pid = self()

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/70/attempts/1/jobs"} => fn conn ->
            send(pid, :listed)

            GitHubStub.json(conn, 200, %{
              "jobs" => [
                listed(repo, id: 80, run_id: 70, status: "completed", conclusion: "failure"),
                listed(repo, id: 81, run_id: 70, status: "in_progress")
              ]
            })
          end
        })
      )

      assert :ok = Reconciler.check_queued()
      assert_received :listed
      refute_received :listed

      assert %{gh_state: "completed", conclusion: "failure"} = Jobs.get_job!(running.id)
      assert Jobs.get_job!(queued.id).gh_state == "in_progress"
    end

    test "one with an event in the last hour, or checked lately, is left alone", %{repo: repo} do
      fresh = hosted_job(repo, id: 82, run_id: 71, status: "in_progress")
      age_job(fresh, 50 * 60)

      checked = hosted_job(repo, id: 83, run_id: 72, status: "in_progress")
      checked = age_job(checked, 3 * 3600)
      at = DateTime.add(DateTime.utc_now(), -60)
      Repo.update!(Ecto.Changeset.change(checked, checked_at: at))

      GitHubStub.stub(%{})
      assert :ok = Reconciler.check_queued()
      assert Jobs.get_job!(fresh.id).checked_at == nil
      assert Jobs.get_job!(checked.id).checked_at == at
    end

    test "a repo the App lost isn't re-checked", %{repo: repo} do
      job = hosted_job(repo, id: 84, run_id: 73, status: "in_progress")
      age_job(job, 2 * 3600)

      Repo.update!(
        Ecto.Changeset.change(Crew.Repos.get!(repo.id), archived_at: DateTime.utc_now())
      )

      GitHubStub.stub(%{})
      assert :ok = Reconciler.check_queued()
      assert Jobs.get_job!(job.id).checked_at == nil
    end

    test "a check counts for every job of the attempt, so a matrix costs one call per 5 minutes",
         %{repo: repo, inst: inst} do
      first = hosted_job(repo, id: 87, run_id: 76, status: "in_progress")
      second = hosted_job(repo, id: 88, run_id: 76, status: "in_progress")
      age_job(first, 2 * 3600)
      # Not stale yet: the listing covers it anyway.
      age_job(second, 50 * 60)

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/76/attempts/1/jobs"} =>
            {200,
             %{
               "jobs" => [
                 listed(repo, id: 87, run_id: 76, status: "in_progress"),
                 listed(repo, id: 88, run_id: 76, status: "in_progress")
               ]
             }}
        })
      )

      assert :ok = Reconciler.check_queued()
      assert Jobs.get_job!(first.id).checked_at
      assert Jobs.get_job!(second.id).checked_at
    end
  end

  describe "open run attempts (§8.8)" do
    defp open_attempt(repo, run_id, job_state) do
      {:ok, attempt} =
        Jobs.handle_workflow_run(workflow_run_payload(repo, id: run_id, status: "in_progress"))

      {:ok, job} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: run_id * 10,
            run_id: run_id,
            labels: ["ubuntu-latest"],
            status: job_state,
            conclusion: if(job_state == "completed", do: "success")
          )
        )

      {attempt, job}
    end

    defp run_json(repo, id, status),
      do:
        workflow_run_payload(repo,
          id: id,
          status: status,
          conclusion: if(status == "completed", do: "success")
        )["workflow_run"]

    test "one with every job done and quiet for 15 minutes is fetched until GitHub says it's done",
         %{repo: repo, inst: inst} do
      {attempt, job} = open_attempt(repo, 90, "completed")
      age_job(job, 16 * 60)
      pid = self()

      fetched = fn status ->
        fn conn ->
          send(pid, :fetched)
          GitHubStub.json(conn, 200, run_json(repo, 90, status))
        end
      end

      # Its jobs only just finished on GitHub's side.
      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/90/attempts/1"} =>
            fetched.("in_progress")
        })
      )

      assert :ok = Reconciler.check_attempts()
      assert_received :fetched
      assert %{status: "in_progress", checked_at: %DateTime{}} = Jobs.get_run_attempt(attempt.id)

      # Not again for 5 minutes.
      assert :ok = Reconciler.check_attempts()
      refute_received :fetched

      Repo.update!(
        Ecto.Changeset.change(Jobs.get_run_attempt(attempt.id),
          checked_at: DateTime.add(DateTime.utc_now(), -301)
        )
      )

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/90/attempts/1"} => fetched.("completed")
        })
      )

      assert :ok = Reconciler.check_attempts()
      assert_received :fetched
      assert %{status: "completed", conclusion: "success"} = Jobs.get_run_attempt(attempt.id)
    end

    test "a failed fetch is tried again 5 minutes later", %{repo: repo, inst: inst} do
      {attempt, job} = open_attempt(repo, 91, "completed")
      age_job(job, 16 * 60)

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/91/attempts/1"} =>
            {404, %{"message" => "Not Found"}}
        })
      )

      assert :ok = Reconciler.check_attempts()
      assert %{status: "in_progress", checked_at: %DateTime{}} = Jobs.get_run_attempt(attempt.id)
    end

    test "one with a job still going, a recent job event, or in a lost repo is left alone",
         %{repo: repo} do
      {running, job} = open_attempt(repo, 92, "in_progress")
      age_job(job, 2 * 3600)
      {recent, job} = open_attempt(repo, 93, "completed")
      age_job(job, 10 * 60)

      lost_repo = repo_fixture(name: "lost")
      {lost, job} = open_attempt(lost_repo, 94, "completed")
      age_job(job, 2 * 3600)
      Repo.update!(Ecto.Changeset.change(lost_repo, archived_at: DateTime.utc_now()))

      GitHubStub.stub(%{})
      assert :ok = Reconciler.check_attempts()

      for a <- [running, recent, lost],
          do: assert(Jobs.get_run_attempt(a.id).checked_at == nil)
    end

    test "every reconciler run checks them", %{repo: repo, inst: inst} do
      :persistent_term.put({Reconciler, :swept_at}, System.monotonic_time(:second))
      on_exit(fn -> :persistent_term.erase({Reconciler, :swept_at}) end)
      {attempt, job} = open_attempt(repo, 95, "completed")
      age_job(job, 16 * 60)

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs/95/attempts/1"} =>
            {200, run_json(repo, 95, "completed")}
        })
      )

      assert :ok = perform_job(Reconciler, %{})
      assert Jobs.get_run_attempt(attempt.id).status == "completed"
    end
  end

  describe "missed jobs" do
    test "the sweep lists a repo's queued and in-progress runs and adds jobs Crew doesn't know",
         %{repo: repo, inst: inst} do
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: 10,
            run_id: 60,
            status: "completed",
            conclusion: "success"
          )
        )

      GitHubStub.stub(
        Map.merge(token(inst), %{
          {"GET", "/repos/#{repo.full_name}/actions/runs"} => fn conn ->
            conn = Plug.Conn.fetch_query_params(conn)

            runs =
              case conn.query_params["status"] do
                "queued" -> [workflow_run_payload(repo, id: 61)["workflow_run"]]
                "in_progress" -> []
              end

            GitHubStub.json(conn, 200, %{"workflow_runs" => runs})
          end,
          {"GET", "/repos/#{repo.full_name}/actions/runs/61/attempts/1/jobs"} =>
            {200, %{"jobs" => [workflow_job_payload(repo, id: 11, run_id: 61)["workflow_job"]]}}
        })
      )

      assert {:ok, %{repos: 1, added: 1}} = Reconciler.sweep_missed()
      job = Jobs.get_job_by_github_id(11)
      assert job.classification == "ours"
      # The run attempt came with the listing, so there's no fork check to wait on.
      assert job.blocked_reason == nil
    end

    test "only repos with Crew jobs in the last 7 days are swept", %{repo: _repo} do
      quiet = repo_fixture(name: "quiet")
      GitHubStub.stub(%{})
      assert {:ok, %{repos: 0}} = Reconciler.sweep_missed()
      refute quiet.archived_at
    end
  end

  test "the first run after boot sweeps (perform/1, not just sweep_missed/0)", %{repo: repo} do
    :persistent_term.erase({Reconciler, :swept_at})
    {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 12, run_id: 62))
    pid = self()

    GitHubStub.stub(%{
      {"POST", "/app/installations/#{repo.installation.github_id}/access_tokens"} =>
        {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
      {"GET", "/repos/#{repo.full_name}/actions/runs"} => fn conn ->
        send(pid, :swept)
        GitHubStub.json(conn, 200, %{"workflow_runs" => []})
      end
    })

    assert :ok = perform_job(Reconciler, %{})
    assert_received :swept
  end

  describe "poll-only mode (§8.8)" do
    test "the sweep interval follows the budget" do
      assert Reconciler.poll_interval(1, 5000) == 15
      # 3600 × 3 × 40 ÷ (0.3 × 5000) = 288
      assert Reconciler.poll_interval(40, 5000) == 288
      assert Reconciler.poll_interval(0, 5000) == 15
    end
  end

  describe "redelivery (§6.2)" do
    test "asks GitHub to redeliver failed deliveries Crew never got, back to the newest it processed" do
      Repo.insert!(%Crew.GitHub.Delivery{
        github_delivery_id: "g-done",
        event: "workflow_job",
        received_at: DateTime.utc_now(),
        processed_at: DateTime.utc_now()
      })

      now = DateTime.utc_now() |> DateTime.to_iso8601()
      pid = self()

      GitHubStub.stub(%{
        {"GET", "/app/hook/deliveries"} =>
          {200,
           [
             %{
               "id" => 3,
               "guid" => "g-missed",
               "status_code" => 502,
               "delivered_at" => now,
               "redelivery" => false
             },
             %{
               "id" => 2,
               "guid" => "g-ok",
               "status_code" => 202,
               "delivered_at" => now,
               "redelivery" => false
             },
             %{
               "id" => 1,
               "guid" => "g-done",
               "status_code" => 202,
               "delivered_at" => now,
               "redelivery" => false
             },
             %{
               "id" => 0,
               "guid" => "g-older",
               "status_code" => 502,
               "delivered_at" => now,
               "redelivery" => false
             }
           ]},
        {"POST", "/app/hook/deliveries/3/attempts"} => fn conn ->
          send(pid, {:redeliver, 3})
          GitHubStub.json(conn, 202, %{})
        end
      })

      assert {:ok, 1} = Crew.GitHub.Redeliver.run()
      assert_received {:redeliver, 3}
      refute_received {:redeliver, _}
    end
  end
end
