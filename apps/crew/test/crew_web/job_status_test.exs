defmodule CrewWeb.JobStatusTest do
  use ExUnit.Case, async: true

  alias CrewWeb.JobStatus

  @now ~U[2026-11-03 10:05:00Z]

  defp job(attrs) do
    Map.merge(
      %{
        classification: "ours",
        gh_state: "queued",
        blocked_reason: nil,
        wait_reason: nil,
        unsatisfiable_reason: nil,
        conclusion: nil,
        runner_name: nil,
        queued_at: ~U[2026-11-03 10:03:48Z],
        seen_at: nil,
        started_at: nil,
        completed_at: nil
      },
      Map.new(attrs)
    )
  end

  test "a queued job shows why it waits, and what Crew is doing about it" do
    assert %{label: "Waiting · 1m 12s", reason: "booting a runner on m4"} =
             JobStatus.of(job(wait_reason: "booting a runner on m4"), @now)

    assert %{label: "Waiting · 1m 12s", reason: nil} = JobStatus.of(job(wait_reason: nil), @now)
  end

  test "the vocabulary of §17.4" do
    assert %{label: "Waiting · 1m 12s", icon: "hero-clock"} = JobStatus.of(job([]), @now)

    assert %{label: "Blocked", reason: "checking fork status"} =
             JobStatus.of(job(blocked_reason: "checking fork status"), @now)

    assert %{label: "Running · 3m 04s"} =
             JobStatus.of(
               job(gh_state: "in_progress", started_at: ~U[2026-11-03 10:01:56Z]),
               @now
             )

    assert %{label: "Succeeded in 4m 31s", icon: "hero-check-circle"} =
             JobStatus.of(
               job(
                 gh_state: "completed",
                 conclusion: "success",
                 started_at: ~U[2026-11-03 10:00:00Z],
                 completed_at: ~U[2026-11-03 10:04:31Z]
               ),
               @now
             )

    assert %{label: "Failed in 2m 10s"} =
             JobStatus.of(
               job(
                 gh_state: "completed",
                 conclusion: "failure",
                 started_at: ~U[2026-11-03 10:00:00Z],
                 completed_at: ~U[2026-11-03 10:02:10Z]
               ),
               @now
             )

    assert %{label: "Cancelled"} =
             JobStatus.of(job(gh_state: "completed", conclusion: "cancelled"), @now)

    assert %{label: "Skipped"} =
             JobStatus.of(job(gh_state: "completed", conclusion: "skipped"), @now)

    assert %{label: "Can't run", reason: "size xl not allowed for this repo"} =
             JobStatus.of(
               job(
                 classification: "unsatisfiable",
                 unsatisfiable_reason: "size xl not allowed for this repo"
               ),
               @now
             )

    assert %{label: "Refused", icon: "hero-shield-exclamation"} =
             JobStatus.of(
               job(
                 classification: "unsatisfiable",
                 unsatisfiable_reason: "fork PRs are refused on this repo"
               ),
               @now
             )

    assert %{label: "Not a Crew job", reason: "ran on ubuntu-24.04"} =
             JobStatus.of(job(classification: "not_ours", runner_name: "ubuntu-24.04"), @now)
  end

  test "every status has an icon or is muted, and text" do
    for attrs <- [[], [gh_state: "waiting"], [classification: "not_ours"]] do
      s = JobStatus.of(job(attrs), @now)
      assert s.label != ""
      assert s.icon != "" or s.tone == :muted
    end
  end

  test "durations" do
    assert JobStatus.format(45) == "45s"
    assert JobStatus.format(184) == "3m 04s"
    assert JobStatus.format(3720) == "1h 02m"
  end
end
