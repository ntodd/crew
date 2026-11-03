defmodule CrewGuest.StepsTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.Steps

  @moduletag :tmp_dir

  @setup "6c5d4e3f-2222-4222-8222-000000000001"
  @checkout "7f1c2a0e-5b8d-4c3e-9a1f-2d4e6b8c0a13"
  @tests "8e2d3b1f-6c9e-4d4f-8b2a-3e5f7c9d1b24"
  @job "5b4c3d2e-1111-4111-8111-000000000000"

  setup %{tmp_dir: dir} do
    test = self()

    steps =
      start_supervised!(
        {Steps,
         diag_dir: dir,
         tick_ms: 20,
         on_steps: fn steps -> send(test, {:steps, steps}) end,
         on_job_started: fn -> send(test, :job_started) end}
      )

    %{steps: steps}
  end

  defp latest(timeout \\ 1_000) do
    receive do
      {:steps, steps} -> latest_after(steps)
    after
      timeout -> flunk("no steps")
    end
  end

  defp latest_after(steps) do
    receive do
      {:steps, steps} -> latest_after(steps)
    after
      100 -> steps
    end
  end

  defp by_ref(steps, ref), do: Enum.find(steps, &(&1.ref == ref))

  test "with no worker log, steps are Step 1…n in page order", %{steps: s} do
    Steps.activity(s, @setup, 1_000, 2_000)
    Steps.activity(s, @checkout, 3_000, 4_000)

    assert [
             %{
               ref: @setup,
               name: "Step 1",
               number: 1,
               status: "completed",
               started_at: 1_000,
               completed_at: 2_000,
               conclusion: nil
             },
             %{
               ref: @checkout,
               name: "Step 2",
               number: 2,
               status: "in_progress",
               completed_at: nil
             }
           ] = latest()
  end

  test "more activity on a running step moves its last line, not its start", %{steps: s} do
    Steps.activity(s, @setup, 1_000, 2_000)
    Steps.activity(s, @setup, 2_500, 3_000)
    Steps.activity(s, @checkout, 4_000, 4_000)

    assert %{started_at: 1_000, completed_at: 3_000} = by_ref(latest(), @setup)
  end

  test "finish/1 completes whatever is still running", %{steps: s} do
    Steps.activity(s, @setup, 1_000, 2_000)
    :ok = Steps.finish(s)
    assert [%{status: "completed", completed_at: 2_000}] = latest()
  end

  test "a worker log appearing means the job started", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Worker_20261103-101500-utc.log"), "")
    assert_receive :job_started, 1_000
  end

  test "the default worker log names steps and gives their results", %{steps: s, tmp_dir: dir} do
    # A step's pages appear as it starts; its telemetry is logged as it ends.
    Steps.activity(s, @setup, 1_000, 1_500)
    Steps.activity(s, @checkout, 2_000, 4_000)
    Steps.activity(s, @tests, 4_500, 9_000)
    _ = :sys.get_state(s)
    File.cp!(fixture("worker/Worker_20261103-101500-utc.log"), Path.join(dir, "Worker_1.log"))
    :ok = Steps.finish(s)

    steps = latest()
    assert Enum.map(steps, & &1.name) == ["Step 1", "Run actions/checkout@v4", "Run tests"]
    assert Enum.map(steps, & &1.number) == [1, 2, 3]
    assert %{status: "completed", conclusion: "success"} = by_ref(steps, @checkout)
    assert %{status: "completed", conclusion: "failure"} = by_ref(steps, @tests)
    # Times from the worker log win over page times.
    assert by_ref(steps, @checkout).started_at ==
             DateTime.to_unix(~U[2026-11-03 10:15:02.123Z], :millisecond)
  end

  test "timeline records give names, order and states, and the job isn't a step",
       %{steps: s, tmp_dir: dir} do
    log = Path.join(dir, "Worker_1.log")
    File.cp!(fixture("worker/Worker_timeline.log"), log)
    # The last entry ends when the worker logs the next one.
    File.write!(log, "[2026-11-03 10:15:10Z INFO JobRunner] Job completed.\n", [:append])
    Steps.activity(s, @job, 500, 600)
    Steps.activity(s, @setup, 1_000, 1_500)

    steps = latest()
    refute by_ref(steps, @job)

    assert Enum.map(steps, &{&1.number, &1.name}) == [
             {1, "Set up job"},
             {2, "Run actions/checkout@v4"},
             {3, "Run tests"}
           ]

    assert %{status: "completed", conclusion: "cancelled"} = by_ref(steps, @tests)
  end

  test "a worker log that doesn't parse leaves the page-order fallback",
       %{steps: s, tmp_dir: dir} do
    File.cp!(fixture("worker/Worker_garbage.log"), Path.join(dir, "Worker_1.log"))
    Steps.activity(s, @checkout, 1_000, 2_000)
    :ok = Steps.finish(s)
    assert [%{name: "Step 1", status: "completed"}] = latest()
  end

  test "at most 1000 steps are reported", %{steps: s} do
    for n <- 1..1005 do
      Steps.activity(s, "00000000-0000-4000-8000-#{String.pad_leading("#{n}", 12, "0")}", n, n)
    end

    :ok = Steps.finish(s)
    assert length(latest()) == 1000
  end
end
