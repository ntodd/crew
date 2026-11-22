defmodule Crew.Jobs.SeriesTest do
  use Crew.DataCase

  import Ecto.Query

  alias Crew.Jobs

  test "only jobs taken by a runner count as starts" do
    repo = repo_fixture()
    now = DateTime.utc_now()
    at = DateTime.add(now, -600)

    for runner <- [nil, "", "crew-runner"] do
      job_row_fixture(repo,
        queued_at: at,
        started_at: at,
        completed_at: now,
        conclusion: "cancelled",
        runner_name: runner
      )
    end

    assert Enum.sum_by(Jobs.started_series(now).other, &elem(&1, 1)) == 1
  end

  test "a job queued before the window and cancelled now counted the whole time" do
    repo = repo_fixture()
    {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 50))
    {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 1, run_id: 50))
    now = DateTime.utc_now()

    Repo.update_all(from(j in Crew.Jobs.Job, where: j.id == ^job.id),
      set: [
        classification: "ours",
        queued_at: DateTime.add(now, -7 * 3600),
        started_at: DateTime.add(now, -7 * 3600),
        gh_state: "completed",
        conclusion: "cancelled",
        completed_at: now
      ]
    )

    # Every tick before it was cancelled, now, counts it.
    series = Jobs.queue_series(now)
    assert series.depth |> Enum.drop(-1) |> Enum.all?(fn {_, n} -> n == 1 end)
  end
end
