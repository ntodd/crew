defmodule CrewWeb.SizingLiveTest do
  @moduledoc "The right-sizing page (§7.5): the week's memory, reserved against used, and every hint."
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")

    %{
      conn: log_in(conn, admin),
      admin: admin,
      repo: repo_fixture(name: "app"),
      other: repo_fixture(name: "api")
    }
  end

  test "the week's totals, each repo's share and every hint, the most to free first", %{
    conn: conn,
    repo: repo,
    other: other
  } do
    summarized_jobs_fixture(repo, 5)

    summarized_jobs_fixture(other, 5,
      vcpus: 8,
      memory_mib: 16_384,
      cpu_excess: List.duplicate(0.0, 7)
    )

    summarized_job_fixture(repo, name: "e2e", oom: true, conclusion: "failure")

    {:ok, view, _} = live(conn, ~p"/sizing")

    # 10-minute runs: 6 on m (8 GiB) and 5 on l (16 GiB), 21.3 GiB-hours.
    assert has_element?(view, "#sizing-reserved", "21.3")
    assert has_element?(view, "#sizing-net", "15.3")
    assert has_element?(view, "#sizing-totals", "Applying the hints would free")
    assert has_element?(view, "#sizing-totals", "frees 16.7, takes 1.3")
    assert has_element?(view, "#sizing-needs-more", "1")

    hints = view |> element("#sizing-hints") |> render()
    assert hints =~ "Try xs"
    assert hints =~ "Needs more memory: l"
    {api_at, _} = :binary.match(hints, other.full_name)
    {e2e_at, _} = :binary.match(hints, "Needs more memory")
    assert api_at < e2e_at

    # Each hint can become an issue on its own repo.
    assert has_element?(
             view,
             ~s(#sizing-hints a[href^="https://github.com/#{other.full_name}/issues/new?"]),
             "File issue"
           )

    assert has_element?(
             view,
             ~s(#sizing-hints button[data-copy^="# Move CI · e2e to crew-l"]),
             "Copy as Markdown"
           )

    # One issue per repo, from its row.
    assert has_element?(
             view,
             ~s(#sizing-repo-#{other.id}-issue a[href^="https://github.com/#{other.full_name}/issues/new?"]),
             "File issue"
           )

    assert has_element?(
             view,
             ~s(#sizing-repo-#{repo.id}-issue button[data-copy^="# Right-size 2 jobs in #{repo.full_name}"])
           )

    assert has_element?(view, ~s(#sizing-repos a[href="/repos/#{other.id}"]), other.full_name)
    assert has_element?(view, ~s(#sizing-repos a[href="/repos/#{repo.id}"]), repo.full_name)
  end

  test "when the hints take more than they free, it says take", %{conn: conn, repo: repo} do
    summarized_job_fixture(repo, name: "e2e", oom: true, conclusion: "failure")

    {:ok, view, _} = live(conn, ~p"/sizing")
    assert has_element?(view, "#sizing-totals", "Applying the hints would take")
    assert has_element?(view, "#sizing-net", "1.3")
    assert has_element?(view, "#sizing-hints", "takes 1.3 GiB-hours a week")
    assert has_element?(view, "#sizing-repo-rows", "takes 1.3")
  end

  test "a member sees only the repos they can read", %{repo: repo, other: other} do
    summarized_jobs_fixture(repo, 5)
    summarized_jobs_fixture(other, 5)
    member = user_fixture()

    Crew.Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    {:ok, view, _} = live(log_in(build_conn(), member), ~p"/sizing")
    assert has_element?(view, "#sizing-repos", repo.full_name)
    refute render(view) =~ other.full_name
  end

  test "with no runs to go on, it says so", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sizing")
    assert has_element?(view, "#sizing-hints-empty")
    assert has_element?(view, "#sizing-repos-empty")
    assert has_element?(view, "#sizing-reserved", "0")
  end

  describe "size changes" do
    @l [vcpus: 8, memory_mib: 16_384, cpu_excess: List.duplicate(0.0, 7)]

    defp ran(repo, hours, seconds, attrs) do
      started = DateTime.utc_now() |> DateTime.add(-hours * 3600) |> DateTime.truncate(:second)

      summarized_job_fixture(
        repo,
        [started_at: started, completed_at: DateTime.add(started, seconds)] ++ attrs
      )
    end

    test "a job that moved: from and to, its time on each, and what it frees", %{
      conn: conn,
      repo: repo
    } do
      for h <- [240, 200, 160], do: ran(repo, h, 600, @l)
      newest = for(h <- [40, 30, 20], do: ran(repo, h, 590, [])) |> List.last()

      {:ok, view, _} = live(conn, ~p"/sizing")
      row = "#sizing-change-#{newest.id}"
      assert has_element?(view, row, "CI · test")
      assert has_element?(view, row, repo.full_name)
      assert has_element?(view, row, "l (8 vCPU · 16.0 GiB) → m (4 vCPU · 8.0 GiB)")
      assert has_element?(view, row, "No slower")
      assert has_element?(view, row, "10m 00s on l, 9m 50s on m")
      assert has_element?(view, row, "frees")

      assert has_element?(
               view,
               ~s(#{row} a[href="/runs/#{newest.github_run_id}/attempts/1/jobs/#{newest.github_id}"])
             )
    end

    test "slower, or killed for memory, says so", %{conn: conn, repo: repo, other: other} do
      for h <- [240, 200, 160], do: ran(repo, h, 600, @l)
      slow = for(h <- [40, 30, 20], do: ran(repo, h, 700, [])) |> List.last()
      for h <- [240, 200, 160], do: ran(other, h, 600, @l)
      killed = ran(other, 10, 60, oom: true, conclusion: "failure")

      {:ok, view, _} = live(conn, ~p"/sizing")
      assert has_element?(view, "#sizing-change-#{slow.id}", "17% slower")
      assert has_element?(view, "#sizing-change-#{killed.id}", "Killed for memory on m")
    end

    test "slower than runs that took no time at all, without a percentage", %{
      conn: conn,
      repo: repo
    } do
      for h <- [240, 200, 160], do: ran(repo, h, 0, @l)
      newest = for(h <- [40, 30, 20], do: ran(repo, h, 5, [])) |> List.last()

      {:ok, view, _} = live(conn, ~p"/sizing")
      assert has_element?(view, "#sizing-change-#{newest.id}", "Slower")
      refute has_element?(view, "#sizing-change-#{newest.id}", "% slower")
    end

    test "nothing when no job moved", %{conn: conn, repo: repo} do
      summarized_jobs_fixture(repo, 5)
      {:ok, view, _} = live(conn, ~p"/sizing")
      refute has_element?(view, "#sizing-changes")
    end
  end

  describe "sizes that would fit" do
    @busy [name: "build", cpu_excess: [1200.0, 600.0, 120.0]]

    test "custom hints by shape, each with the jobs it fits and a link to add it", %{
      conn: conn,
      repo: repo,
      other: other
    } do
      summarized_jobs_fixture(repo, 5, @busy)
      summarized_jobs_fixture(other, 5, @busy)

      {:ok, view, _} = live(conn, ~p"/sizing")
      shape = "#sizing-custom-4-2048-20"
      assert has_element?(view, shape, "4 vCPU · 2.0 GiB · 20 GiB disk")
      assert has_element?(view, shape, "2 jobs")
      assert has_element?(view, shape, "CI · build")
      assert has_element?(view, shape, repo.full_name)
      assert has_element?(view, shape, other.full_name)
      assert has_element?(view, shape, "GiB-hours a week")

      [a, b] = Enum.sort([repo.id, other.id])

      [href] =
        view
        |> element("#{shape} a", "Add this size")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("href")

      %URI{path: "/admin/sizes", query: query} = URI.parse(href)

      assert %{"vcpus" => "4", "memory_mib" => "2048", "disk_gib" => "20", "repos" => repos} =
               Plug.Conn.Query.decode(query)

      assert Enum.sort(repos) == [a, b]
    end

    test "none without custom hints; no link for a member", %{repo: repo} do
      summarized_jobs_fixture(repo, 5)
      member = user_fixture()

      Crew.Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/sizing")
      refute has_element?(view, "#sizing-custom")

      summarized_jobs_fixture(repo, 5, @busy)
      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/sizing")
      assert has_element?(view, "#sizing-custom", "An admin can add it")
      refute has_element?(view, "#sizing-custom a[href^='/admin/sizes']")
    end
  end

  describe "dismissing a hint" do
    test "an admin dismisses one, with why: it leaves the hints and the totals, and comes back",
         %{conn: conn, admin: admin, repo: repo} do
      newest = repo |> summarized_jobs_fixture(5) |> List.last()
      row = "#sizing-#{newest.id}"

      {:ok, view, _} = live(conn, ~p"/sizing")
      assert has_element?(view, "#sizing-hints #{row}", "Try xs")
      refute has_element?(view, "#sizing-dismissed-toggle")

      view |> element("#{row} button", "Dismiss") |> render_click()

      view
      |> form("#{row}-dismiss", %{"reason" => "xs made the tests flaky"})
      |> render_submit()

      refute has_element?(view, "#sizing-hints #{row}")
      assert has_element?(view, "#sizing-hints-empty", "every hint is dismissed")
      assert has_element?(view, "#sizing-net", "0.0")
      assert has_element?(view, "#sizing-repo-rows", "frees 0.0")
      refute has_element?(view, "#sizing-repo-rows a[href*='/issues/new']")

      view |> element("#sizing-dismissed-toggle", "1 dismissed") |> render_click()
      dismissed = "#sizing-dismissed-#{newest.id}"
      assert has_element?(view, dismissed, "CI · test")
      assert has_element?(view, dismissed, "Try xs")
      assert has_element?(view, dismissed, "Dismissed by #{admin.login}")
      assert has_element?(view, dismissed, "xs made the tests flaky")

      view |> element("#{dismissed} button", "Restore") |> render_click()
      assert has_element?(view, "#sizing-hints #{row}", "Try xs")
      refute has_element?(view, "#sizing-dismissed-toggle")
    end

    test "dismissing can be called off", %{conn: conn, repo: repo} do
      newest = repo |> summarized_jobs_fixture(5) |> List.last()
      row = "#sizing-#{newest.id}"

      {:ok, view, _} = live(conn, ~p"/sizing")
      view |> element("#{row} button", "Dismiss") |> render_click()
      assert has_element?(view, "#{row}-dismiss")
      view |> element("#{row}-dismiss button", "Cancel") |> render_click()
      refute has_element?(view, "#{row}-dismiss")
      assert has_element?(view, "#sizing-hints #{row}")
    end

    test "a member sees what's dismissed, but can't dismiss or restore", %{
      admin: admin,
      repo: repo
    } do
      newest = repo |> summarized_jobs_fixture(5) |> List.last()
      summarized_job_fixture(repo, name: "e2e", oom: true, conclusion: "failure")
      %{kind: kind, from: from} = Crew.Sizing.for_job(newest)

      {:ok, _} =
        Crew.Sizing.dismiss(Crew.Scope.for_user(admin), newest.id, %{
          "kind" => to_string(kind),
          "vcpus" => to_string(from.vcpus),
          "memory_mib" => to_string(from.memory_mib),
          "reason" => "flaky"
        })

      member = user_fixture()

      Crew.Repo.insert!(%Crew.Repos.Access{
        user_id: member.id,
        repo_id: repo.id,
        checked_at: DateTime.utc_now()
      })

      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/sizing")
      refute has_element?(view, "#sizing-hints button", "Dismiss")
      view |> element("#sizing-dismissed-toggle") |> render_click()
      assert has_element?(view, "#sizing-dismissed-#{newest.id}", "flaky")
      refute has_element?(view, "#sizing-dismissed button", "Restore")

      # Nor by sending the events.
      render_hook(view, "dismiss_hint", %{"job_id" => newest.id, "reason" => ""})
      assert has_element?(view, "#sizing-hints", "Needs more memory")
      d = Crew.Sizing.dismissal(newest, Crew.Sizing.for_job(newest))
      assert render_hook(view, "restore_hint", %{"id" => d.id}) =~ "Only admins"
      assert Crew.Sizing.dismissal(newest, Crew.Sizing.for_job(newest))
    end
  end

  test "the sidebar links to it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(nav a[href="/sizing"]), "Right-sizing")
  end
end
