defmodule CrewWeb.RepoLiveTest do
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")
    %{conn: log_in(conn, admin), repo: repo_fixture(name: "app")}
  end

  test "lists the repos", %{conn: conn, repo: repo} do
    {:ok, view, _} = live(conn, ~p"/repos")
    assert has_element?(view, "#repo-#{repo.id}", repo.full_name)
  end

  test "the repo page shows a runs-on snippet per allowed size", %{conn: conn, repo: repo} do
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

    for size <- ~w(xs s m l xl),
        do: assert(has_element?(view, "#snippets", "runs-on: crew-#{size}"))

    Crew.Repo.update!(Ecto.Changeset.change(repo, allowed_sizes: ["s"]))
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
    assert has_element?(view, "#snippets", "runs-on: crew-s")
    refute has_element?(view, "#snippets", "runs-on: crew-m")
  end

  test "admins change settings, and queued jobs are re-parsed", %{conn: conn, repo: repo} do
    {:ok, job} = Crew.Jobs.handle_workflow_job(workflow_job_payload(repo, labels: ["crew-xl"]))
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

    view
    |> form("#repo-settings", %{
      "repo" => %{"fork_prs" => "allow", "priority" => "3", "allowed_sizes" => ["s", "m"]}
    })
    |> render_submit()

    assert render(view) =~ "Saved"
    repo = Crew.Repos.get!(repo.id)
    assert {repo.fork_prs, repo.priority, repo.allowed_sizes} == {"allow", 3, ["s", "m"]}
    assert Crew.Jobs.get_job!(job.id).unsatisfiable_reason == "size xl not allowed for this repo"
  end

  test "settings errors are shown", %{conn: conn, repo: repo} do
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

    html =
      view |> form("#repo-settings", %{"repo" => %{"max_concurrent" => "0"}}) |> render_submit()

    assert html =~ "must be greater than 0"
  end

  test "missing App permissions are flagged", %{conn: conn} do
    installation = installation_fixture(permissions: %{"metadata" => "read", "actions" => "read"})
    repo = repo_fixture(installation: installation)
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
    assert has_element?(view, "#missing-permissions", "administration")
    assert has_element?(view, "#missing-permissions", "actions")
  end

  test "members see readable repos only, and no settings form", %{repo: repo} do
    member = user_fixture()
    other = repo_fixture(name: "open")

    Crew.Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: other.id,
      checked_at: DateTime.utc_now()
    })

    conn = log_in(build_conn(), member)

    {:ok, view, _} = live(conn, ~p"/repos")
    assert has_element?(view, "#repo-#{other.id}")
    refute has_element?(view, "#repo-#{repo.id}")

    {:ok, view, _} = live(conn, ~p"/repos/#{other.id}")
    refute has_element?(view, "#repo-settings")
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/repos/#{repo.id}") end
  end
end
