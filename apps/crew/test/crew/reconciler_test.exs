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
