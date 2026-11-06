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

  test "a running or waiting job says since when, so a page can count it up" do
    started = ~U[2026-11-03 10:01:56Z]

    assert %{verb: "Running", since: ^started} =
             JobStatus.of(job(gh_state: "in_progress", started_at: started), @now)

    assert %{verb: "Waiting", since: %DateTime{}} = JobStatus.of(job([]), @now)
    assert %{since: nil} = JobStatus.of(job(blocked_reason: "checking fork status"), @now)

    assert %{since: nil} =
             JobStatus.of(job(gh_state: "completed", conclusion: "success"), @now)
  end

  test "the vocabulary of §17.4" do
    assert %{label: "Waiting · 1m 12s", icon: "hero-clock-micro"} = JobStatus.of(job([]), @now)

    assert %{label: "Blocked", reason: "checking fork status"} =
             JobStatus.of(job(blocked_reason: "checking fork status"), @now)

    assert %{label: "Running · 3m 04s"} =
             JobStatus.of(
               job(gh_state: "in_progress", started_at: ~U[2026-11-03 10:01:56Z]),
               @now
             )

    assert %{label: "Succeeded in 4m 31s", icon: "hero-check-circle-micro"} =
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

    assert %{label: "Refused", icon: "hero-shield-exclamation-micro"} =
             JobStatus.of(
               job(
                 classification: "unsatisfiable",
                 unsatisfiable_reason: "fork PRs are refused on this repo"
               ),
               @now
             )
  end

  test "a job that isn't Crew's says how it went on GitHub, and that it isn't Crew's" do
    not_ours = &job([classification: "not_ours", runner_name: "ubuntu-24.04"] ++ &1)

    assert %{
             state: "success",
             label: "Succeeded in 4m 31s",
             reason: "not a Crew job, ran on ubuntu-24.04",
             tone: :success,
             ours: false
           } =
             JobStatus.of(
               not_ours.(
                 gh_state: "completed",
                 conclusion: "success",
                 started_at: ~U[2026-11-03 10:00:00Z],
                 completed_at: ~U[2026-11-03 10:04:31Z]
               ),
               @now
             )

    assert %{state: "failure", tone: :danger} =
             JobStatus.of(not_ours.(gh_state: "completed", conclusion: "failure"), @now)

    assert %{state: "running", verb: "Running", label: "Running · 3m 04s"} =
             JobStatus.of(
               not_ours.(gh_state: "in_progress", started_at: ~U[2026-11-03 10:01:56Z]),
               @now
             )

    assert %{state: "queued", verb: "Queued", label: "Queued · 1m 12s", reason: "not a Crew job"} =
             JobStatus.of(job(classification: "not_ours"), @now)

    assert %{ours: true} = JobStatus.of(job([]), @now)
  end

  test "a job that isn't Crew's keeps what GitHub said, before saying whose it was" do
    assert %{label: "Completed", reason: "timed_out, not a Crew job, ran on ubuntu-24.04"} =
             JobStatus.of(
               job(
                 classification: "not_ours",
                 runner_name: "ubuntu-24.04",
                 gh_state: "completed",
                 conclusion: "timed_out"
               ),
               @now
             )

    assert %{label: "Waiting", reason: "for an environment approval, not a Crew job"} =
             JobStatus.of(job(classification: "not_ours", gh_state: "waiting"), @now)
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
