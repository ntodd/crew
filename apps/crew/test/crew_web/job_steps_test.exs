defmodule CrewWeb.JobStepsTest do
  @moduledoc "A job's steps as the run page shows them, and its progress through them."
  use ExUnit.Case, async: true

  alias CrewWeb.JobSteps

  @api [
    %{"number" => 1, "name" => "Set up job", "status" => "completed", "conclusion" => "success"},
    %{"number" => 2, "name" => "Run tests", "status" => "in_progress", "conclusion" => nil}
  ]

  @guest [
    %{number: 1, name: "Set up job", status: "completed", conclusion: "success"},
    %{number: 2, name: "Checkout", status: "completed", conclusion: "success"},
    %{number: 3, name: "Run tests", status: "in_progress", conclusion: nil},
    %{number: 4, name: "Lint", status: "pending", conclusion: nil}
  ]

  test "a running job's steps are the guest's, which are live" do
    steps = JobSteps.of(%{gh_state: "in_progress", steps: @api}, @guest)
    assert Enum.map(steps, & &1.name) == ["Set up job", "Checkout", "Run tests", "Lint"]
  end

  test "otherwise GitHub's, else the guest's, in step order" do
    assert [%{name: "Set up job"}, %{name: "Run tests"}] =
             JobSteps.of(%{gh_state: "completed", steps: Enum.reverse(@api)}, @guest)

    assert length(JobSteps.of(%{gh_state: "completed", steps: []}, @guest)) == 4
    assert JobSteps.of(%{gh_state: "in_progress", steps: @api}, []) |> length() == 2
    assert JobSteps.of(%{gh_state: "queued", steps: []}, []) == []
  end

  test "each step's state, for the bar" do
    states =
      %{gh_state: "in_progress", steps: []}
      |> JobSteps.of(@guest)
      |> Enum.map(&JobSteps.state/1)

    assert states == ["success", "success", "running", "pending"]

    assert JobSteps.state(%{status: "completed", conclusion: "failure"}) == "failure"
    assert JobSteps.state(%{status: "completed", conclusion: "skipped"}) == "skipped"
    assert JobSteps.state(%{status: "completed", conclusion: "cancelled"}) == "cancelled"
    assert JobSteps.state(%{status: "queued", conclusion: nil}) == "pending"
  end

  test "a step done with no known outcome is done, not a success" do
    steps = [
      %{number: 1, name: "a", status: "completed", conclusion: "success"},
      %{number: 2, name: "b", status: "completed", conclusion: nil},
      %{number: 3, name: "c", status: "in_progress", conclusion: nil}
    ]

    assert Enum.map(steps, &JobSteps.state/1) == ["success", "done", "running"]
    assert %{done: 2, total: 3, current: "c"} = JobSteps.progress(steps)
  end

  test "progress: steps done of all, the one running, and the first that failed" do
    live = JobSteps.of(%{gh_state: "in_progress", steps: []}, @guest)
    assert %{done: 2, total: 4, current: "Run tests", failed: nil} = JobSteps.progress(live)

    failed = [
      %{number: 1, name: "a", status: "completed", conclusion: "success"},
      %{number: 2, name: "b", status: "completed", conclusion: "failure"},
      %{number: 3, name: "c", status: "completed", conclusion: "skipped"}
    ]

    assert %{done: 3, total: 3, current: nil, failed: "b"} = JobSteps.progress(failed)
    assert JobSteps.progress([]) == nil
  end

  describe "times and what a step says on hover" do
    test "GitHub's ISO times and the guest's Unix milliseconds both come out as DateTimes" do
      [api] =
        JobSteps.of(
          %{
            gh_state: "completed",
            steps: [
              %{
                "number" => 1,
                "name" => "Build",
                "status" => "completed",
                "conclusion" => "success",
                "started_at" => "2026-11-03T10:00:00Z",
                "completed_at" => "2026-11-03T10:00:04Z"
              }
            ]
          },
          []
        )

      assert api.started_at == ~U[2026-11-03 10:00:00Z]
      assert api.completed_at == ~U[2026-11-03 10:00:04Z]

      [guest] =
        JobSteps.of(%{gh_state: "in_progress", steps: []}, [
          %{
            number: 1,
            name: "Build",
            status: "in_progress",
            conclusion: nil,
            started_at: 1_793_700_000_000
          }
        ])

      assert guest.started_at == DateTime.from_unix!(1_793_700_000_000, :millisecond)
      assert guest.completed_at == nil
    end

    test "which step it is of how many, and how it went or since when it's been going" do
      done = %{
        number: 2,
        name: "Checkout",
        status: "completed",
        conclusion: "success",
        started_at: ~U[2026-11-03 10:00:00Z],
        completed_at: ~U[2026-11-03 10:00:04Z]
      }

      assert JobSteps.describe(done, 7) ==
               %{title: "Step 2 of 7 · Checkout", outcome: "succeeded in 4s", since: nil}

      running = %{
        done
        | number: 4,
          name: "Run tests",
          status: "in_progress",
          conclusion: nil,
          completed_at: nil
      }

      assert JobSteps.describe(running, 7) ==
               %{
                 title: "Step 4 of 7 · Run tests",
                 outcome: "running",
                 since: ~U[2026-11-03 10:00:00Z]
               }

      assert %{outcome: "failed in 4s"} = JobSteps.describe(%{done | conclusion: "failure"}, 7)

      assert %{outcome: "skipped"} =
               JobSteps.describe(%{done | conclusion: "skipped", started_at: nil}, 7)

      assert %{outcome: "done"} =
               JobSteps.describe(%{done | conclusion: nil, completed_at: nil}, 7)

      assert %{title: "Step 5 of 7 · Step 5", outcome: "not started"} =
               JobSteps.describe(%{number: 5, name: nil, status: "pending", conclusion: nil}, 7)
    end

    test "progress names the number of the step running, or the one that failed" do
      steps = [
        %{number: 1, name: "a", status: "completed", conclusion: "failure"},
        %{number: 2, name: "b", status: "in_progress", conclusion: nil}
      ]

      assert %{current: "b", current_number: 2, failed: "a", failed_number: 1} =
               JobSteps.progress(steps)
    end
  end

  describe "which steps, for both pages" do
    test "a running job with the guest's steps uses them; otherwise GitHub's, else the guest's" do
      api = [%{"number" => 1, "name" => "Set up job", "status" => "completed"}]
      guest = [%{number: 1, name: "Set up job", status: "completed", conclusion: "success"}]

      assert JobSteps.source(%{gh_state: "in_progress", steps: api}, guest) == :guest
      assert JobSteps.source(%{gh_state: "in_progress", steps: api}, []) == :api
      assert JobSteps.source(%{gh_state: "completed", steps: api}, guest) == :api
      assert JobSteps.source(%{gh_state: "completed", steps: []}, guest) == :guest
    end

    test "a time no clock could hold is no time, not a crash" do
      [step] =
        JobSteps.of(%{gh_state: "in_progress", steps: []}, [
          %{number: 1, name: "a", status: "in_progress", started_at: 10 ** 20}
        ])

      assert step.started_at == nil
    end
  end
end
