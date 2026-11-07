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

  defp shown(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#repos-panel li[id^=repo-]")
    |> LazyHTML.attribute("id")
  end

  defp ids(repos), do: Enum.map(repos, &"repo-#{&1.id}")

  describe "filtering the list" do
    setup do
      %{
        site: repo_fixture(name: "Site", private: false),
        legacy: repo_fixture(name: "legacy-app", enabled: false),
        urgent: repo_fixture(name: "urgent", priority: 5),
        slow: repo_fixture(name: "slow", priority: -1)
      }
    end

    test "the search matches part of the name, in any case, and lives in the URL", %{
      conn: conn,
      repo: repo,
      legacy: legacy
    } do
      {:ok, view, _} = live(conn, ~p"/repos?q=APP")
      assert shown(view) == ids([repo, legacy])
      assert has_element?(view, "#repo-search[value=APP]")

      view |> form("#repo-filters", %{"q" => " site "}) |> render_change()
      assert_patch(view, ~p"/repos?q=site")
      assert has_element?(view, "#repos-panel li", "acme/Site")
      assert length(shown(view)) == 1
    end

    test "the state, visibility and priority toggles", %{conn: conn} = ctx do
      {:ok, view, _} = live(conn, ~p"/repos?state=disabled")
      assert shown(view) == ids([ctx.legacy])

      {:ok, view, _} = live(conn, ~p"/repos?state=enabled")
      refute "repo-#{ctx.legacy.id}" in shown(view)

      {:ok, view, _} = live(conn, ~p"/repos?visibility=public")
      assert shown(view) == ids([ctx.site])

      {:ok, view, _} = live(conn, ~p"/repos?visibility=private")
      refute "repo-#{ctx.site.id}" in shown(view)

      {:ok, view, _} = live(conn, ~p"/repos?priority=true")
      assert shown(view) == ids([ctx.slow, ctx.urgent])

      view
      |> form("#repo-filters", %{"priority" => "true", "visibility" => "public"})
      |> render_change()

      assert_patch(view, ~p"/repos?#{%{priority: "true", visibility: "public"}}")
      assert shown(view) == []
    end

    test "the search covers the owner too", %{conn: conn, legacy: legacy} do
      {:ok, view, _} = live(conn, ~p"/repos?q=acme/le")
      assert shown(view) == ids([legacy])
    end

    test "values the filters don't know are ignored", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/repos?state=archived&visibility=x&priority=yes&q=")
      assert length(shown(view)) == 5
      refute has_element?(view, "#repos-no-match")

      {:ok, view, _} =
        live(conn, "/repos?q[]=app&state[]=disabled&visibility[x]=public&priority[]=true&sort=x")

      assert length(shown(view)) == 5
    end

    test "how many repos the filters leave is announced", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/repos")
      assert has_element?(view, "#repo-count[role=status]", "5 repos")

      {:ok, view, _} = live(conn, ~p"/repos?state=disabled")
      assert has_element?(view, "#repo-count", "1 of 5 repos")

      {:ok, view, _} = live(conn, ~p"/repos?q=nope")
      assert has_element?(view, "#repo-count", "0 of 5 repos")
    end

    test "nothing matching has its own empty state, with a way out", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/repos?q=nope")
      assert shown(view) == []
      assert has_element?(view, "#repos-no-match", "No repos match")
      refute has_element?(view, "#repos-empty")

      view |> element("#repos-no-match a", "Clear filters") |> render_click()
      assert_patch(view, ~p"/repos")
      assert length(shown(view)) == 5
    end
  end

  test "with no repos at all, the install hint shows and the filters don't", %{conn: conn} do
    Crew.Repo.delete_all(Crew.Repos.Repo)
    {:ok, view, _} = live(conn, ~p"/repos?q=app")
    assert has_element?(view, "#repos-empty", "Install the App")
    refute has_element?(view, "#repos-no-match")
    refute has_element?(view, "#repo-filters")
    refute has_element?(view, "#repo-count")
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

    {:ok, view, _} = live(conn, ~p"/repos?q=app")
    refute has_element?(view, "#repo-#{repo.id}")
    assert has_element?(view, "#repos-no-match")

    {:ok, view, _} = live(conn, ~p"/repos/#{other.id}")
    refute has_element?(view, "#repo-settings")
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/repos/#{repo.id}") end
  end
end
