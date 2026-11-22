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

    assert has_element?(view, ~s(#fleet a[href="/boxes"]), "View boxes")
    assert has_element?(view, "#fleet", "1 needs attention")
    refute has_element?(view, "#fleet", box.name)
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

  test "fleet totals weight fresh online telemetry and keep reservations on offline boxes", %{
    box: offline
  } do
    small = box_fixture(capabilities: capabilities(vcpus: 4))
    large = box_fixture(capabilities: capabilities(vcpus: 12), draining: true)
    stale = box_fixture()
    silent = box_fixture()

    for box <- [small, large, stale, silent] do
      :ok = Crew.Agents.register(box.id)
    end

    now = System.os_time(:second)

    box_metric_fixture(small, now,
      cpu_pct: 100.0,
      mem_used_mib: 500,
      mem_total_mib: 1000,
      vm_area_free_mib: 1000
    )

    box_metric_fixture(large, now,
      cpu_pct: 0.0,
      mem_used_mib: 2500,
      mem_total_mib: 3000,
      vm_area_free_mib: 2000
    )

    box_metric_fixture(stale, now - 120)
    box_metric_fixture(offline, now)
    vm_fixture(offline, state: "busy")
    vm_fixture(small, state: "idle")

    fleet = CrewWeb.Fleet.overview()
    assert %{boxes: 5, online: 4, reporting: 2, draining: 1, attention: 1} = fleet
    assert %{cpu_pct: 25, memory_pct: 75, disk_free_mib: 3000} = fleet
    assert %{provisioned_vcpus: 8, provisioned_memory_mib: 16_640} = fleet
    assert %{total: 2, busy: 1, idle: 1} = fleet.vms
  end

  test "outcomes and throughput use independent rolling windows for Crew jobs", %{repo: repo} do
    now = ~U[2026-12-01 12:01:10.000000Z]
    since = DateTime.add(now, -86_400)

    job_row_fixture(repo,
      started_at: DateTime.add(since, -10),
      completed_at: DateTime.add(since, 1)
    )

    job_row_fixture(repo, started_at: now, gh_state: "in_progress", conclusion: nil)
    job_row_fixture(repo, started_at: since, completed_at: since)
    job_row_fixture(repo, started_at: DateTime.add(now, 1), completed_at: DateTime.add(now, 2))
    job_row_fixture(repo, completed_at: now, classification: "other")
    job_row_fixture(repo, completed_at: now, conclusion: "skipped")
    assert Jobs.completed_outcomes(now) == %{"success" => 1, "skipped" => 1}
    starts = Jobs.started_series(now)
    assert length(starts.other) == 48
    assert List.last(starts.other) == {DateTime.to_unix(now) - 900, 1}
    assert Enum.sum_by(starts.success, &elem(&1, 1)) == 0
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
    assert has_element?(view, "#fleet", "No boxes online")
    assert has_element?(view, "#chart-started", "No Crew jobs started")
    assert has_element?(view, "#job-outcomes", "0 completed")

    assert %{reporting: 0, cpu_pct: nil, memory_pct: nil, disk_free_mib: nil} =
             CrewWeb.Fleet.overview()
  end
end
