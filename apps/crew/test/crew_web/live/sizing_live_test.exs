defmodule CrewWeb.SizingLiveTest do
  @moduledoc "The right-sizing page (§7.5): the week's memory, reserved against used, and every hint."
  use CrewWeb.ConnCase

  setup %{conn: conn} do
    admin = user_fixture(role: "admin")

    %{
      conn: log_in(conn, admin),
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

  test "the sidebar links to it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(nav a[href="/sizing"]), "Right-sizing")
  end
end
