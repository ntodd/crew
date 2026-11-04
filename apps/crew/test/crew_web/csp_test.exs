defmodule CrewWeb.CSPTest do
  @moduledoc """
  Production's CSP has `style-src 'self'` (§17.1): an inline `style`
  attribute is blocked, so no page may render one. Sizes and positions
  go through the CSSOM from assets/js instead.
  """
  use CrewWeb.ConnCase

  alias Crew.Jobs

  @inline ~r/<[^>]+\sstyle="/

  setup %{conn: conn} do
    repo = repo_fixture(name: "web")
    box_fixture(name: "m4")
    {:ok, _} = Jobs.handle_workflow_run(workflow_run_payload(repo, id: 555))

    for n <- 1..20 do
      {:ok, _} =
        Jobs.handle_workflow_job(
          workflow_job_payload(repo,
            id: n,
            run_id: 555,
            status: "completed",
            conclusion: "success"
          )
        )
    end

    %{conn: log_in(conn, user_fixture(role: "admin")), box: Crew.Boxes.list() |> hd()}
  end

  test "no page renders an inline style attribute", %{conn: conn, box: box} do
    for path <- [
          "/",
          "/runs",
          "/runs/555/attempts/1",
          "/runs/555/attempts/1/jobs/1",
          "/queue",
          "/repos",
          "/boxes",
          "/boxes/#{box.id}",
          "/admin",
          "/admin/users",
          "/admin/audit"
        ] do
      {:ok, _view, html} = live(conn, path)

      refute Regex.match?(@inline, html),
             "#{path} has an inline style: #{inspect(Regex.run(@inline, html))}"
    end
  end
end
