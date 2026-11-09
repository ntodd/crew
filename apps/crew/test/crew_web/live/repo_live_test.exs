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

  test "a line under the snippets explains -spare", %{conn: conn, repo: repo} do
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
    assert has_element?(view, "#spare-hint", "runs-on: crew-spare")
    assert has_element?(view, "#spare-hint", "runs-on: crew-xl-spare")

    Crew.Repo.update!(Ecto.Changeset.change(repo, allowed_sizes: ["s"]))
    {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
    assert has_element?(view, "#spare-hint", "runs-on: crew-s-spare")
    # The default size (m) isn't allowed, so crew-spare wouldn't run.
    refute has_element?(view, "#spare-hint", "runs-on: crew-spare")
  end

  describe "right-sizing (§7.5)" do
    test "lists each job with a change to suggest, linked to its newest run", %{
      conn: conn,
      repo: repo
    } do
      [_ | _] = jobs = summarized_jobs_fixture(repo, 5, name: "test")
      summarized_jobs_fixture(repo, 5, name: "e2e", peak_mem_mib: 5000)
      newest = List.last(jobs)

      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#sizing", "Try xs")
      assert has_element?(view, "#sizing", "frees 6.0 GiB a run")

      assert has_element?(
               view,
               ~s(#sizing a[href="/runs/#{newest.github_run_id}/attempts/1/jobs/#{newest.github_id}"]),
               "CI · test"
             )

      # e2e fits m.
      refute has_element?(view, "#sizing", "e2e")
    end

    test "says when there's nothing to change", %{conn: conn, repo: repo} do
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#sizing-empty")

      summarized_jobs_fixture(repo, 5, name: "e2e", peak_mem_mib: 5000)
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#sizing-empty")
    end
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

  describe "schedules" do
    setup %{repo: repo} do
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

      test = self()

      Crew.GitHubStub.stub(%{
        {"POST", "/app/installations/#{repo.installation.github_id}/access_tokens"} =>
          {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
        {"POST", "/repos/#{repo.full_name}/actions/workflows/flake-hunt.yml/dispatches"} =>
          fn conn ->
            send(test, {:dispatched, Crew.GitHubStub.body(conn)})
            Plug.Conn.send_resp(conn, 204, "")
          end
      })

      :ok
    end

    test "an admin adds a schedule, sees it listed with its next run, and removes it", %{
      conn: conn,
      repo: repo
    } do
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#schedules-empty")

      view
      |> form("#schedule-form",
        schedule: %{workflow: "flake-hunt.yml", ref: "main", cron: "17 7 * * *"}
      )
      |> render_submit()

      [s] = Crew.Schedules.list(repo.id)
      assert has_element?(view, "#schedule-#{s.id}", "flake-hunt.yml")
      assert has_element?(view, "#schedule-#{s.id}", "17 7 * * *")
      assert has_element?(view, "#schedule-#{s.id} time")
      refute has_element?(view, "#schedules-empty")

      view |> element("#schedule-#{s.id} button", "Remove") |> render_click()
      refute has_element?(view, "#schedule-#{s.id}")
      assert Crew.Schedules.list(repo.id) == []
    end

    test "a bad cron is refused with the reason", %{conn: conn, repo: repo} do
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

      html =
        view
        |> form("#schedule-form", schedule: %{workflow: "ci.yml", ref: "main", cron: "17 7"})
        |> render_submit()

      assert html =~ "five fields"
      assert Crew.Schedules.list(repo.id) == []
    end

    test "run now dispatches at once; disable and enable flip the schedule", %{
      conn: conn,
      repo: repo
    } do
      s = schedule_fixture(repo)
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

      view |> element("#schedule-#{s.id} button", "Run now") |> render_click()
      assert_received {:dispatched, %{"ref" => "main"}}
      assert render(view) =~ "Started flake-hunt.yml on main"
      assert Crew.Repo.reload!(s).last_dispatched_at

      view |> element("#schedule-#{s.id} button", "Disable") |> render_click()
      refute Crew.Repo.reload!(s).enabled
      assert has_element?(view, "#schedule-#{s.id}", "Off")

      view |> element("#schedule-#{s.id} button", "Enable") |> render_click()
      assert Crew.Repo.reload!(s).enabled
    end

    test "a failed dispatch shows GitHub's answer on the schedule", %{conn: conn, repo: repo} do
      Crew.GitHubStub.stub(%{
        {"POST", "/app/installations/#{repo.installation.github_id}/access_tokens"} =>
          {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
        {"POST", "/repos/#{repo.full_name}/actions/workflows/flake-hunt.yml/dispatches"} =>
          {422, %{"message" => "Workflow does not have 'workflow_dispatch' trigger"}}
      })

      s = schedule_fixture(repo)
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

      view |> element("#schedule-#{s.id} button", "Run now") |> render_click()
      assert has_element?(view, "#schedule-#{s.id}", "workflow_dispatch")
    end

    test "members see no schedules", %{repo: repo} do
      member = user_fixture(role: "member")

      Crew.Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        can_push: false,
        checked_at: DateTime.utc_now()
      })

      schedule_fixture(repo)
      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/repos/#{repo.id}")
      refute has_element?(view, "#schedules")
      refute has_element?(view, "#schedule-form")
    end
  end
end
