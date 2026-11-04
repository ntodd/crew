defmodule CrewWeb.StackViewTest do
  @moduledoc "The Runs stack view (§17.3): by branch, with superseded runs folded under the newest."
  use CrewWeb.ConnCase

  alias Crew.Jobs

  setup %{conn: conn} do
    repo = repo_fixture(name: "app")

    for {id, branch, sha, at, workflow} <- [
          {801, "feat/a", "aaaa111", "2026-11-03T09:00:00Z", "CI"},
          {802, "feat/a", "bbbb222", "2026-11-03T10:00:00Z", "CI"},
          {803, "feat/a", "bbbb222", "2026-11-03T10:00:05Z", "Lint"},
          {804, "feat/b", "cccc333", "2026-11-03T09:30:00Z", "CI"}
        ] do
      payload =
        workflow_run_payload(repo, id: id, head_branch: branch, head_sha: sha, name: workflow)

      payload = put_in(payload, ["workflow_run", "created_at"], at)
      {:ok, _} = Jobs.handle_workflow_run(payload)
    end

    %{conn: log_in(conn, user_fixture(role: "admin")), repo: repo}
  end

  test "groups by branch, newest first, with older SHAs folded", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs?view=stack")

    assert has_element?(view, "[data-branch='feat/a'] [data-current] [data-run='802']")
    assert has_element?(view, "[data-branch='feat/a'] [data-current] [data-run='803']")

    assert has_element?(
             view,
             "[data-branch='feat/a'] details[data-superseded] [data-run='801']",
             "aaaa111"
           )

    assert has_element?(
             view,
             "[data-branch='feat/a'] details[data-superseded] summary",
             "1 superseded"
           )

    assert has_element?(view, "[data-branch='feat/b'] [data-current] [data-run='804']")

    # Newest branch first.
    html = render(view)
    {a, _} = :binary.match(html, ~s(data-branch="feat/a"))
    {b, _} = :binary.match(html, ~s(data-branch="feat/b"))
    assert a < b
  end

  test "a toggle switches between the list and the stack, kept in the URL", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/runs")
    view |> element("#view-stack") |> render_click()
    assert_patch(view, ~p"/runs?view=stack")
    view |> element("#view-list") |> render_click()
    assert_patch(view, ~p"/runs")
  end

  test "each group is headed by its branch, with ids unique across repos", %{
    conn: conn,
    repo: repo
  } do
    other = repo_fixture(name: "lib")

    for {r, id} <- [{repo, 805}, {other, 806}] do
      {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(r, id: id, head_branch: "main"))
    end

    {:ok, _} =
      Jobs.handle_workflow_run(workflow_run_payload(repo, id: 807, head_branch: "feat-a"))

    {:ok, view, html} = live(conn, ~p"/runs?view=stack")

    assert has_element?(view, "[data-branch='feat/a'] h2", "feat/a")
    ids = Regex.scan(~r/id="(stack-\d+)"/, html, capture: :all_but_first) |> List.flatten()
    assert length(ids) == 5
    assert ids == Enum.uniq(ids)
  end
end
