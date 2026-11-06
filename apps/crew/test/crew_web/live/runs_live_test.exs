defmodule CrewWeb.RunsLiveTest do
  use CrewWeb.ConnCase

  alias Crew.Jobs

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")
    repo = repo_fixture(name: "app")
    %{conn: log_in(conn, admin), repo: repo}
  end

  defp run_with_jobs(repo, run_id, jobs, run_attrs \\ []) do
    {:ok, attempt} =
      Jobs.handle_workflow_run(workflow_run_payload(repo, [id: run_id] ++ run_attrs))

    for {id, attrs} <- jobs do
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(
            repo,
            [id: id, run_id: run_id, run_attempt: attempt.run_attempt] ++ attrs
          )
        )
    end

    attempt
  end

  test "lists run attempts newest first, with their jobs' states", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 100, [{1, labels: ["crew-m"]}, {2, labels: ["ubuntu-latest"]}],
      name: "CI",
      run_number: 7
    )

    run_with_jobs(repo, 101, [{3, labels: ["crew-l"]}], name: "Deploy", run_number: 8)

    {:ok, view, html} = live(conn, ~p"/runs")
    assert html =~ "acme/app"

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("[data-run]")
           |> LazyHTML.attribute("data-run") == ["101", "100"]

    assert has_element?(view, "#run-100", "CI")
    assert has_element?(view, "#run-100", "#7")
    assert has_element?(view, "#run-100 [data-job-state=queued]")
    assert has_element?(view, "#run-100 [data-job-state=not_ours]")
  end

  test "updates live when a webhook lands", %{conn: conn, repo: repo} do
    {:ok, view, _} = live(conn, ~p"/runs")
    refute has_element?(view, "#run-102")
    run_with_jobs(repo, 102, [{4, labels: ["crew-m"]}])
    # PubSub updates are coalesced, then flushed (§17.5).
    :timer.sleep(300)
    assert has_element?(view, "#run-102")
  end

  test "filters live in the URL", %{conn: conn, repo: repo} do
    other = repo_fixture(name: "site")
    run_with_jobs(repo, 103, [{5, []}], head_branch: "main")
    run_with_jobs(other, 104, [{6, []}], head_branch: "feature/x")

    {:ok, view, _} = live(conn, ~p"/runs?repo=#{other.full_name}")
    refute has_element?(view, "#run-103")
    assert has_element?(view, "#run-104")

    {:ok, view, _} = live(conn, ~p"/runs?q=main")
    assert has_element?(view, "#run-103")
    refute has_element?(view, "#run-104")

    view |> form("#run-filters", %{"status" => "queued"}) |> render_change()
    assert_patch(view, ~p"/runs?q=main&status=queued")
  end

  test "branch, PR and actor share one search box", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 120, [{40, []}], head_branch: "feature/x")
    run_with_jobs(repo, 121, [{41, []}], head_branch: "main")

    {:ok, view, _} = live(conn, ~p"/runs")
    assert has_element?(view, ~s(#run-filters input[type="search"][name="q"]))
    refute has_element?(view, ~s(#run-filters input[name="branch"]))
    refute has_element?(view, ~s(#run-filters input[name="pr"]))
    refute has_element?(view, ~s(#run-filters input[name="actor"]))

    view |> form("#run-filters", %{"q" => "feature"}) |> render_change()
    assert_patch(view, ~p"/runs?q=feature")
    assert has_element?(view, "#run-120")
    refute has_element?(view, "#run-121")
  end

  test "Crew jobs only hides runs with no job for Crew", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 122, [{42, labels: ["crew-m"]}])
    run_with_jobs(repo, 123, [{43, labels: ["ubuntu-latest"]}])

    {:ok, view, _} = live(conn, ~p"/runs")
    assert has_element?(view, "#run-123")

    view |> form("#run-filters", %{"crew" => "true", "status" => "queued"}) |> render_change()
    assert_patch(view, ~p"/runs?crew=true&status=queued")
    assert has_element?(view, "#run-122")
    refute has_element?(view, "#run-123")

    # Unchecked, the box sends nothing; the other filters stay.
    view |> render_change("filter", %{"status" => "queued"})
    assert_patch(view, ~p"/runs?status=queued")
    assert has_element?(view, "#run-123")
  end

  test "a toggle that's off or an unknown status in the URL isn't a filter", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs?crew=false&mine=no&q=&status=garbage")
    assert has_element?(view, "#runs-empty", "No runs yet")
  end

  test "the search box explains the qualifiers to screen readers", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs")
    assert has_element?(view, ~s(#run-search[aria-describedby="run-search-help"]))
    assert has_element?(view, "#run-search-help", "branch:")
  end

  test "the repo, PR and commit link to GitHub in a new tab", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 124, [{44, []}],
      head_sha: "f00dfacecafe",
      pull_requests: [%{"number" => 718}]
    )

    run_with_jobs(repo, 125, [{45, []}], head_branch: "release/v2")
    run_with_jobs(repo, 128, [{48, []}], head_branch: "feat/a#b+c")

    {:ok, view, _} = live(conn, ~p"/runs")

    for href <- [
          "https://github.com/acme/app",
          "https://github.com/acme/app/pull/718",
          "https://github.com/acme/app/commit/f00dfacecafe"
        ] do
      assert has_element?(
               view,
               ~s(#run-124 a[href="#{href}"][target="_blank"][rel~="noopener"])
             )
    end

    assert has_element?(view, ~s(#run-124 a[href$="/pull/718"]), "PR #718")
    assert has_element?(view, ~s(#run-124 a[href$="/commit/f00dfacecafe"]), "f00dfac")

    assert has_element?(
             view,
             ~s(#run-125 a[href="https://github.com/acme/app/tree/release/v2"][target="_blank"]),
             "release/v2"
           )

    assert has_element?(
             view,
             ~s(#run-128 a[href="https://github.com/acme/app/tree/feat/a%23b%2Bc"]),
             "feat/a#b+c"
           )
  end

  test "no matches says so, not that there are no runs", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 127, [{47, []}])

    {:ok, view, _} = live(conn, ~p"/runs?q=nothing-matches&view=stack")
    assert has_element?(view, "#runs-empty", "No runs match")
    refute has_element?(view, "#runs-empty", "No runs yet")
    view |> element("#runs-empty a", "Clear filters") |> render_click()
    assert_patch(view, ~p"/runs?view=stack")
    assert has_element?(view, ~s([data-run="127"]))
  end

  test "a run's status icon is solid", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 126, [{46, []}], status: "completed", conclusion: "success")
    {:ok, view, _} = live(conn, ~p"/runs")
    assert has_element?(view, ~s(#run-126 [class~="hero-check-circle-micro"]))
  end

  test "earlier attempts fold under the latest", %{conn: conn, repo: repo} do
    run_with_jobs(repo, 105, [{7, conclusion: "failure", status: "completed"}],
      run_attempt: 1,
      status: "completed",
      conclusion: "failure"
    )

    run_with_jobs(repo, 105, [{8, []}], run_attempt: 2)

    {:ok, view, html} = live(conn, ~p"/runs")

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(~s([data-run="105"]))
           |> Enum.count() == 1

    assert has_element?(view, "#run-105", "attempt 2")
    assert has_element?(view, "#run-105 a[href$=\"/attempts/1\"]")
  end

  describe "the run page" do
    test "shows the header and each job with Crew's status", %{conn: conn, repo: repo} do
      attempt =
        run_with_jobs(
          repo,
          106,
          [
            {10, labels: ["crew-m"], name: "test"},
            {11, labels: ["crew-huge"], name: "huge"},
            {12,
             labels: ["ubuntu-latest"],
             name: "lint",
             status: "completed",
             conclusion: "success",
             runner_name: "GitHub Actions 2",
             completed_at: "2026-11-03T10:01:00Z"}
          ],
          message: "Make it faster",
          run_number: 9
        )

      {:ok, view, html} = live(conn, ~p"/runs/#{attempt.github_run_id}/attempts/1")
      assert html =~ "Make it faster"
      assert has_element?(view, "#job-10", "Waiting")
      assert has_element?(view, "#job-11", "Can't run")
      assert has_element?(view, "#job-11", "unknown size huge")
      assert has_element?(view, "#job-12", "Not a Crew job")
      assert has_element?(view, "#job-12", "GitHub Actions 2")
    end

    test "a blocked job says why", %{conn: conn, repo: repo} do
      {:ok, job} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 13, run_id: 107))
      {:ok, attempt} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 107))

      Crew.Repo.update!(
        Ecto.Changeset.change(Jobs.get_job!(job.id), blocked_reason: "no arm64 box")
      )

      {:ok, view, _} = live(conn, ~p"/runs/#{attempt.github_run_id}/attempts/1")
      assert has_element?(view, "#job-13", "Blocked")
      assert has_element?(view, "#job-13", "no arm64 box")
    end

    test "a refused fork PR says so", %{conn: conn, repo: repo} do
      {:ok, _} = Jobs.handle_workflow_job(workflow_job_payload(repo, id: 14, run_id: 108))

      {:ok, attempt} =
        Jobs.handle_workflow_run(
          workflow_run_payload(repo, id: 108, event: "pull_request", head_repo: "stranger/app")
        )

      {:ok, view, _} = live(conn, ~p"/runs/#{attempt.github_run_id}/attempts/1")
      assert has_element?(view, "#job-14", "Refused")
      assert has_element?(view, "#job-14", "fork PRs are refused on this repo")
    end
  end

  describe "as a member" do
    test "only runs of repos they can read are shown, and others' run pages 404", %{repo: repo} do
      member = user_fixture()
      readable = repo_fixture(name: "open")

      Crew.Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: readable.id,
        checked_at: DateTime.utc_now()
      })

      hidden = run_with_jobs(repo, 109, [{15, []}])
      run_with_jobs(readable, 110, [{16, []}])

      conn = log_in(build_conn(), member)
      {:ok, view, _} = live(conn, ~p"/runs")
      assert has_element?(view, "#run-110")
      refute has_element?(view, "#run-109")
      refute render(view) =~ repo.full_name

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/runs/#{hidden.github_run_id}/attempts/1")
      end
    end
  end

  test "a member whose access to the repo is dropped is sent away from its run", %{repo: repo} do
    member = user_fixture()

    Crew.Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    attempt = run_with_jobs(repo, 111, [{17, []}])

    {:ok, view, _} =
      live(log_in(build_conn(), member), ~p"/runs/#{attempt.github_run_id}/attempts/1")

    Crew.Repo.delete_all(Crew.Repos.Access)
    Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{member.id}", {:repo_access_changed, [repo.id]})
    assert_redirect(view, ~p"/runs")
  end

  test "the Runs list drops a repo whose access is dropped", %{repo: repo} do
    member = user_fixture()

    Crew.Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    run_with_jobs(repo, 112, [{18, []}])

    {:ok, view, _} = live(log_in(build_conn(), member), ~p"/runs")
    assert has_element?(view, "#run-112")
    Crew.Repo.delete_all(Crew.Repos.Access)
    Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{member.id}", {:repo_access_changed, [repo.id]})
    assert_redirect(view, ~p"/runs")
  end

  test "the sidebar links to Runs", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/runs"]), "Runs")
  end
end
