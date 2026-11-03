defmodule Crew.GitHub.HookWorkerTest do
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.GitHub.HookWorker

  setup do
    %{repo: repo_fixture(name: "app")}
  end

  defp run(event, payload, delivery \\ Ecto.UUID.generate()) do
    :new = HookWorker.record(delivery, event, payload["action"], payload)

    perform_job(HookWorker, %{
      "event" => event,
      "action" => payload["action"],
      "delivery_id" => delivery,
      "payload" => payload
    })
  end

  test "workflow_job upserts the job and marks the delivery processed", %{repo: repo} do
    payload = workflow_job_payload(repo, id: 901)
    assert :ok = run("workflow_job", payload, "dlv-1")
    assert Crew.Jobs.get_job_by_github_id(901)
    assert Repo.get!(Crew.GitHub.Delivery, "dlv-1").processed_at
  end

  test "workflow_run upserts the run attempt", %{repo: repo} do
    assert :ok = run("workflow_run", workflow_run_payload(repo, id: 902))
    assert Repo.get_by(Crew.Jobs.RunAttempt, github_run_id: 902)
  end

  test "installation deleted archives the repos", %{repo: repo} do
    assert :ok =
             run("installation", %{
               "action" => "deleted",
               "installation" => %{"id" => repo.installation.github_id}
             })

    assert Repo.reload!(repo).archived_at
  end

  test "installation_repositories adds and removes", %{repo: repo} do
    payload = %{
      "action" => "added",
      "installation" => %{"id" => repo.installation.github_id},
      "repositories_added" => [%{"id" => 555, "full_name" => "acme/fresh", "private" => false}],
      "repositories_removed" => [%{"id" => repo.github_id, "full_name" => repo.full_name}]
    }

    assert :ok = run("installation_repositories", payload)
    assert Crew.Repos.get_by_full_name("acme/fresh")
    assert Repo.reload!(repo).archived_at
  end

  test "two repositories added in a row are both processed", %{repo: repo} do
    for {gid, name} <- [{601, "one"}, {602, "two"}] do
      payload = %{
        "action" => "added",
        "installation" => %{"id" => repo.installation.github_id},
        "repositories_added" => [%{"id" => gid, "full_name" => "acme/#{name}", "private" => true}],
        "repositories_removed" => []
      }

      :new =
        HookWorker.record(Ecto.UUID.generate(), "installation_repositories", "added", payload)
    end

    assert length(all_enqueued(worker: HookWorker)) == 2
  end

  test "ping is recorded for the Deployment page" do
    assert :ok = run("ping", %{"zen" => "Keep it logically awesome.", "hook_id" => 7})
    assert %{"hook_id" => 7, "at" => _} = Crew.Settings.get("webhook_ping")
  end

  test "other events are acknowledged and dropped" do
    assert :ok = run("star", %{"action" => "created"})
  end

  test "a failure is recorded on the delivery and retried", %{repo: _} do
    payload = %{
      "action" => "queued",
      "workflow_job" => %{"id" => 1, "status" => "queued"},
      "repository" => %{"id" => -1},
      "installation" => %{}
    }

    assert {:error, _} = run("workflow_job", payload, "dlv-bad")
    delivery = Repo.get!(Crew.GitHub.Delivery, "dlv-bad")
    assert delivery.error
    refute delivery.processed_at
  end
end
