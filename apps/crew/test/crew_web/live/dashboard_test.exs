defmodule CrewWeb.DashboardTest do
  @moduledoc "The dashboard (§17.3): fleet, counters, waiting, recent, charts, activity."
  use CrewWeb.ConnCase

  alias Crew.{Jobs, Repo}

  setup do
    repo = repo_fixture(name: "web")
    hidden = repo_fixture(name: "secret")
    box = box_fixture(name: "m4pro")

    {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 600))
    {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(hidden, id: 601))

    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 1,
          run_id: 600,
          name: "waits",
          created_at: "2026-11-03T09:00:00Z"
        )
      )

    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo, id: 2, run_id: 600, name: "runs", status: "in_progress")
      )

    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 3,
          run_id: 600,
          name: "done",
          status: "completed",
          conclusion: "success",
          completed_at: "2026-11-03T10:05:00Z"
        )
      )

    {:ok, _} =
      Jobs.handle_workflow_job(
        workflow_job_payload(hidden,
          id: 4,
          run_id: 601,
          name: "private-job",
          status: "completed",
          conclusion: "failure",
          completed_at: "2026-11-03T10:06:00Z"
        )
      )

    # A pass gives the waiting jobs their reasons.
    Crew.Scheduler.pass()
    %{repo: repo, hidden: hidden, box: box}
  end

  test "fleet, counters, waiting and recent jobs, and charts", %{conn: conn, box: box} do
    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/")

    assert has_element?(view, "#fleet #fleet-#{box.id}", "m4pro")
    assert has_element?(view, "#fleet-#{box.id}", "Offline")
    assert has_element?(view, ~s(#counters a[href="/runs?status=in_progress"]), "1")
    assert has_element?(view, ~s(#counters a[href="/runs?status=queued"]), "1")
    assert has_element?(view, "#counters", "Booting")
    assert has_element?(view, "#waiting li", "waits")
    assert has_element?(view, "#waiting li", "the only boxes that fit are offline")
    assert has_element?(view, "#recent li", "done")
    assert has_element?(view, "#chart-started")
    assert has_element?(view, "#chart-wait")
    refute has_element?(view, "#dashboard-empty")
  end

  test "the waiting counter counts regular jobs, and notes the spare ones", %{
    conn: conn,
    repo: repo
  } do
    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/")
    refute has_element?(view, "#waiting-spare")

    for id <- [11, 12] do
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo, id: id, run_id: 600, labels: ["crew-l-spare"])
        )
    end

    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/")
    assert has_element?(view, ~s(#counters a[href="/runs?status=queued"] p.text-2xl), "1")
    assert has_element?(view, "#waiting-spare", "+ 2 spare")
  end

  test "waiting longest lists regular jobs before spare ones, which are tagged", %{
    conn: conn,
    repo: repo
  } do
    {:ok, spare} =
      Jobs.handle_workflow_job(
        workflow_job_payload(repo,
          id: 13,
          run_id: 600,
          name: "fuzz",
          labels: ["crew-l-spare"],
          created_at: "2026-11-03T08:00:00Z"
        )
      )

    {:ok, view, _} = live(log_in(conn, user_fixture(role: "admin")), ~p"/")
    names = view |> element("#waiting") |> render() |> then(&Regex.scan(~r/waits|fuzz/, &1))
    assert names == [["waits"], ["fuzz"]]
    assert has_element?(view, "#waiting-#{spare.id} [data-tier=spare]", "spare")
  end

  test "members see other repos' jobs masked", %{conn: conn, repo: repo, hidden: hidden} do
    member = user_fixture()

    Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(log_in(conn, member), ~p"/")
    assert html =~ "a job in another repo"
    refute html =~ "private-job"
    refute html =~ hidden.full_name
  end

  test "an empty deployment shows how to start" do
    Repo.delete_all(Crew.Jobs.Job)
    Repo.delete_all(Crew.Boxes.Box)
    {:ok, view, _} = live(log_in(build_conn(), user_fixture(role: "admin")), ~p"/")
    assert has_element?(view, "#dashboard-empty #empty-boxes", "Add your first box")
    assert has_element?(view, "#empty-jobs", "runs-on: crew-m")
  end
end
