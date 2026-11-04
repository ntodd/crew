defmodule CrewWeb.QueueLiveTest do
  use CrewWeb.ConnCase

  import Ecto.Query

  alias Crew.{Jobs, Repo}

  setup do
    repo = repo_fixture(name: "api")
    hidden = repo_fixture(name: "secret")
    box_fixture(name: "m4")

    for {r, id} <- [{repo, 1}, {repo, 2}, {hidden, 3}] do
      run = 900 + id
      {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(r, id: run))

      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(r, id: id, run_id: run, name: "job #{id}", labels: ["crew-m"])
        )
    end

    %{repo: repo, hidden: hidden}
  end

  test "waiting units in placement order, with their class, wait and reason; and each class", %{
    conn: conn
  } do
    conn = log_in(conn, user_fixture(role: "admin"))
    {:ok, view, _} = live(conn, ~p"/queue")

    assert has_element?(view, "#units li", "job 1")
    assert has_element?(view, "#units li", "crew-m")
    # The box is offline: the jobs are blocked, with the reason.
    assert has_element?(view, "#units", "the only boxes that fit are offline")
    assert has_element?(view, "#classes", "acme/api")
    assert has_element?(view, "#queue-chart")
  end

  test "admins change a repo's priority here, audited", %{conn: conn, repo: repo} do
    admin = user_fixture(role: "admin")
    {:ok, view, _} = live(log_in(conn, admin), ~p"/queue")

    view |> form("#priority-#{repo.id}", %{"priority" => "7"}) |> render_submit()
    assert Repo.reload!(repo).priority == 7
    assert Repo.exists?(from e in Crew.Audit.Event, where: e.action == "repo.settings")
  end

  test "members see other repos' jobs masked, and no priority controls", %{
    conn: conn,
    repo: repo,
    hidden: hidden
  } do
    member = user_fixture()

    Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    {:ok, view, html} = live(log_in(conn, member), ~p"/queue")

    assert has_element?(view, "#units li", "job 1")
    assert html =~ "a job in another repo"
    refute html =~ hidden.full_name
    refute html =~ "job 3"
    refute has_element?(view, "form[id^=priority-]")
  end

  test "the sidebar links to the queue", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn, user_fixture()), ~p"/")
    assert has_element?(view, ~s(a[href="/queue"]), "Queue")
  end
end
