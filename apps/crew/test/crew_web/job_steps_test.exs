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
end
