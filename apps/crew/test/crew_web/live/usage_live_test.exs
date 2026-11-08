defmodule CrewWeb.UsageLiveTest do
  @moduledoc "The usage page (§16.6, §17.3): job and VM minutes by box, repo and size, by UTC day."
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")

    %{
      conn: log_in(conn, admin),
      repo: repo_fixture(name: "app"),
      other: repo_fixture(name: "api"),
      box: box_fixture(name: "m3-mini")
    }
  end

  defp yesterday, do: Date.add(Date.utc_today(), -1)

  test "the totals, the chart and each breakdown", %{conn: conn, repo: repo, box: box} do
    # 10 minutes busy and 70 s of overhead, and 61 s more of job.
    ran_fixture(box, repo, yesterday(), 600)
    ran_fixture(box, repo, yesterday(), 61, vcpus: 3, memory_mib: 5000)
    Crew.Usage.roll_up()

    {:ok, view, _} = live(conn, ~p"/usage")

    assert has_element?(view, "header", "UTC")
    assert has_element?(view, "#usage-job-minutes", "11")
    assert has_element?(view, "#usage-totals", "12 rounded up per job, as GitHub bills")
    assert has_element?(view, "#usage-vm-minutes", "13")
    assert has_element?(view, "#usage-overhead", "17%")
    assert has_element?(view, "#usage-totals", "boot 1, idle 1, teardown 0 min")
    assert has_element?(view, "#usage-totals", "GiB-hours")
    assert has_element?(view, "#usage-chart", "VM minutes")
    assert has_element?(view, "#usage-chart", "Busy")
    assert has_element?(view, "#usage-chart", "Job minutes")

    assert has_element?(view, ~s(#usage-boxes a[href="/boxes/#{box.id}"]), "m3-mini")
    assert has_element?(view, ~s(#usage-repos a[href="/repos/#{repo.id}"]), repo.full_name)
    assert has_element?(view, "#usage-sizes", "m (4 vCPU · 8.0 GiB)")
    assert has_element?(view, "#usage-sizes", "3 vCPU · 4.9 GiB")
    refute has_element?(view, "#usage-empty")
  end

  test "the range is in the URL, 30 days by default", %{conn: conn, repo: repo, box: box} do
    ran_fixture(box, repo, Date.add(Date.utc_today(), -20), 600)
    Crew.Usage.roll_up()
    Crew.Usage.roll_up()

    {:ok, view, _} = live(conn, ~p"/usage")
    assert has_element?(view, ~s(#range-30[aria-current="true"]))
    assert has_element?(view, "#usage-job-minutes", "10")

    view |> element("#range-7") |> render_click()
    assert_patched(view, ~p"/usage?days=7")
    assert has_element?(view, "#usage-empty")

    {:ok, view, _} = live(conn, ~p"/usage?days=90")
    assert has_element?(view, ~s(#range-90[aria-current="true"]))

    {:ok, view, _} = live(conn, ~p"/usage?days=12")
    assert has_element?(view, ~s(#range-30[aria-current="true"]))
  end

  test "with nothing in the range, it says so", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/usage")
    assert has_element?(view, "#usage-empty")
    refute has_element?(view, "#usage-boxes")
  end

  test "a member sees every box, and the repos they can't read as one row", %{
    repo: repo,
    other: other,
    box: box
  } do
    ran_fixture(box, repo, yesterday(), 600)
    ran_fixture(box, other, yesterday(), 300)
    Crew.Usage.roll_up()
    member = user_fixture()

    Crew.Repo.insert!(%Crew.Repos.Access{
      user_id: member.id,
      repo_id: repo.id,
      checked_at: DateTime.utc_now()
    })

    {:ok, view, _} = live(log_in(build_conn(), member), ~p"/usage")
    assert has_element?(view, "#usage-repos", repo.full_name)
    assert has_element?(view, "#usage-repos", "Other repos")
    refute render(view) =~ other.full_name
    refute has_element?(view, ~s(#usage-repos a[href="/repos/#{other.id}"]))
    assert has_element?(view, ~s(#usage-boxes a[href="/boxes/#{box.id}"]))
    assert has_element?(view, "#usage-job-minutes", "15")
  end

  test "a revoked box says so", %{conn: conn, repo: repo, box: box} do
    ran_fixture(box, repo, yesterday(), 600)
    Crew.Usage.roll_up()

    Crew.Repo.update_all(Crew.Boxes.Box, set: [revoked_at: DateTime.utc_now()])

    {:ok, view, _} = live(conn, ~p"/usage")
    assert has_element?(view, "#usage-boxes", "(revoked)")
  end

  test "the sidebar links to it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(nav a[href="/usage"]), "Usage")
  end

  describe "the dashboard" do
    test "counts today's job minutes, with yesterday's", %{conn: conn, repo: repo, box: box} do
      ran_fixture(box, repo, yesterday(), 600)
      now = DateTime.utc_now() |> Map.put(:microsecond, {0, 6})
      job_row_fixture(repo, started_at: DateTime.add(now, -180), completed_at: now)

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, ~s(#counters a[href="/usage"]), "Job minutes today")
      assert has_element?(view, "#job-minutes-today", "3")
      assert has_element?(view, ~s(#counters a[href="/usage"]), "10 yesterday")
    end
  end
end
