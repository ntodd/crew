defmodule CrewWeb.UsagePanelsTest do
  @moduledoc "The Usage panels on a box's page and a repo's (§16.6, §17.3): their last 30 days."
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    %{
      conn: log_in(conn, user_fixture(role: "admin")),
      repo: repo_fixture(name: "app"),
      other: repo_fixture(name: "api"),
      box: box_fixture(name: "m3-mini")
    }
  end

  defp yesterday, do: Date.add(Date.utc_today(), -1)

  defp member(repos) do
    user = user_fixture()

    for repo <- repos,
        do:
          Crew.Repo.insert!(%Crew.Repos.Access{
            user_id: user.id,
            repo_id: repo.id,
            checked_at: DateTime.utc_now()
          })

    log_in(build_conn(), user)
  end

  describe "a box's page" do
    test "its minutes by phase, its use, a chart and its top repos", %{
      conn: conn,
      repo: repo,
      other: other,
      box: box
    } do
      ran_fixture(box, repo, yesterday(), 1200)
      ran_fixture(box, other, yesterday(), 600)
      ran_fixture(box_fixture(), other, yesterday(), 6000)
      t = DateTime.to_unix(DateTime.new!(yesterday(), ~T[00:00:00], "Etc/UTC"))
      for i <- 0..99, do: box_metric_fixture(box, t + i * 5)
      Crew.Usage.roll_up()

      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")

      panel = element(view, "#usage")
      assert render(panel) =~ "Last 30 days"
      # 1800 s busy, 140 s of overhead.
      assert has_element?(view, "#usage-vm-minutes", "32")
      assert has_element?(view, "#usage-busy", "30")
      assert has_element?(view, "#usage-job-minutes", "30")
      assert has_element?(view, "#usage-mem-use", "%")
      assert has_element?(view, "#usage-vcpu-use", "%")
      assert has_element?(view, "#usage-chart")
      assert has_element?(view, ~s(#usage a[href="/usage"]))

      rows = view |> element("#usage-repos") |> render()
      {app, _} = :binary.match(rows, repo.full_name)
      {api, _} = :binary.match(rows, other.full_name)
      assert app < api
    end

    test "a member sees the repos they can't read as a private repo", %{
      repo: repo,
      other: other,
      box: box
    } do
      ran_fixture(box, repo, yesterday(), 1200)
      ran_fixture(box, other, yesterday(), 600)
      Crew.Usage.roll_up()

      {:ok, view, _} = live(member([repo]), ~p"/boxes/#{box.id}")
      assert has_element?(view, "#usage-repos", repo.full_name)
      assert has_element?(view, "#usage-repos", "a private repo")
      refute render(view) =~ other.full_name
      # The box's own totals, in full.
      assert has_element?(view, "#usage-vm-minutes", "32")
    end

    test "with nothing in the last 30 days, it says so", %{conn: conn, box: box} do
      {:ok, view, _} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "#usage-empty")
    end
  end

  describe "a repo's page" do
    test "its jobs and minutes, a chart and its top jobs", %{
      conn: conn,
      repo: repo,
      other: other,
      box: box
    } do
      ran_fixture(box, repo, yesterday(), 1200)
      ran_fixture(box, repo, yesterday(), 61)
      ran_fixture(box, other, yesterday(), 6000)
      now = DateTime.utc_now() |> Map.put(:microsecond, {0, 6})

      job_row_fixture(repo,
        name: "lint",
        started_at: DateTime.add(now, -3600 - 30),
        completed_at: DateTime.add(now, -3600)
      )

      Crew.Usage.roll_up()

      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")

      assert has_element?(view, "#usage-vm-minutes", "23")
      assert has_element?(view, "#usage-overhead", "%")
      assert has_element?(view, "#usage-chart", "Job minutes")
      assert has_element?(view, ~s(#usage a[href="/usage"]))
      refute has_element?(view, "#usage-jobs")
    end

    test "with nothing in the last 30 days, it says so", %{conn: conn, repo: repo} do
      {:ok, view, _} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#usage-empty")
    end
  end
end
