defmodule CrewWeb.JobBarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CrewWeb.CrewComponents

  defp job(n, attrs) do
    Map.merge(
      %{
        name: "job #{n}",
        classification: "ours",
        gh_state: "queued",
        blocked_reason: nil,
        wait_reason: nil,
        unsatisfiable_reason: nil,
        conclusion: nil,
        runner_name: nil,
        queued_at: ~U[2026-11-03 10:00:00Z],
        seen_at: nil,
        started_at: ~U[2026-11-03 10:00:00Z],
        completed_at: ~U[2026-11-03 10:01:00Z]
      },
      Map.new(attrs)
    )
  end

  test "a segment per job, up to 16" do
    html =
      render_component(&CrewComponents.job_bar/1,
        id: "bar",
        jobs: for(n <- 1..16, do: job(n, []))
      )

    assert length(Regex.scan(~r/data-job-state="queued"/, html)) == 16
  end

  test "past 16, a segment per state, sized by its count, so the bar keeps its width" do
    jobs =
      for(n <- 1..20, do: job(n, gh_state: "completed", conclusion: "success")) ++
        for(n <- 21..30, do: job(n, []))

    html = render_component(&CrewComponents.job_bar/1, id: "bar", jobs: jobs)
    # Sized through the Grow hook: no inline style (§17.1).
    assert html =~ ~r/data-job-state="success"[^>]*data-count="20"[^>]*data-grow="20"/
    assert html =~ ~s(phx-hook="Grow")
    refute html =~ "style="
    assert html =~ ~r/data-job-state="queued"[^>]*data-count="10"/
    assert length(Regex.scan(~r/data-job-state=/, html)) == 2
    assert html =~ ~s(aria-label="20 success, 10 queued")
  end

  # The accent is green, close to success: running work has a color of
  # its own, so a bar of running and passed jobs still reads.
  test "running jobs aren't drawn in the accent or success colors" do
    bar =
      render_component(&CrewComponents.job_bar/1,
        id: "bar",
        jobs: [
          job(1, gh_state: "in_progress"),
          job(2, gh_state: "completed", conclusion: "success")
        ]
      )

    [segment] = Regex.run(~r/<span[^>]*data-job-state="running"[^>]*>/, bar)
    assert segment =~ "bg-running"
    refute bar =~ "bg-accent"

    status = render_component(&CrewComponents.job_status/1, job: job(1, gh_state: "in_progress"))
    assert status =~ "text-running-ink"
    assert status =~ "bg-running"
    refute status =~ "accent"
  end
end
