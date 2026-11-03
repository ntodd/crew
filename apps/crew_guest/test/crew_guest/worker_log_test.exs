defmodule CrewGuest.WorkerLogTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.WorkerLog

  @checkout "7f1c2a0e-5b8d-4c3e-9a1f-2d4e6b8c0a13"
  @tests "8e2d3b1f-6c9e-4d4f-8b2a-3e5f7c9d1b24"
  @setup "6c5d4e3f-2222-4222-8222-000000000001"
  @job "5b4c3d2e-1111-4111-8111-000000000000"

  defp ms(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  defp parse(name), do: name |> fixture() |> File.read!() |> WorkerLog.parse()

  describe "the runner's default worker log" do
    setup do
      %{updates: parse("worker/Worker_20261103-101500-utc.log")}
    end

    test "names the planned steps from the job message", %{updates: updates} do
      assert {:planned, @tests, "Run tests"} in updates
      # A step with no display name token gets its name elsewhere.
      refute Enum.any?(updates, &match?({:planned, @checkout, _}, &1))
    end

    test "takes results and times from the step telemetry", %{updates: updates} do
      assert {:record, checkout} = Enum.find(updates, &match?({:record, %{id: @checkout}}, &1))
      assert checkout.state == "completed"
      assert checkout.conclusion == "success"
      assert checkout.started_at == ms("2026-11-03T10:15:02.123Z")
      assert checkout.completed_at == ms("2026-11-03T10:15:04.765Z")

      assert {:record, %{conclusion: "failure"}} =
               Enum.find(updates, &match?({:record, %{id: @tests}}, &1))
    end

    test "telemetry takes the display name of the step being processed, as a hint",
         %{updates: updates} do
      assert {:record, %{display_name: "Run actions/checkout@v4"}} =
               Enum.find(updates, &match?({:record, %{id: @checkout}}, &1))

      assert {:record, %{display_name: "Run tests"}} =
               Enum.find(updates, &match?({:record, %{id: @tests}}, &1))
    end

    test "ignores objects that aren't timeline records", %{updates: updates} do
      ids = for {_, %{id: id}} <- updates, do: id
      ids = ids ++ for({:planned, id, _} <- updates, do: id)
      assert Enum.sort(Enum.uniq(ids)) == Enum.sort([@checkout, @tests])
    end
  end

  describe "timeline record updates" do
    setup do
      %{updates: parse("worker/Worker_timeline.log")}
    end

    test "carry id, name, order, state and result", %{updates: updates} do
      records = for {:record, r} <- updates, do: r

      assert %{name: "Set up job", order: 1, state: "in_progress"} =
               Enum.find(records, &(&1.id == @setup))

      assert %{state: "completed", conclusion: "success", completed_at: done} =
               records |> Enum.filter(&(&1.id == @setup)) |> List.last()

      assert done == ms("2026-11-03T10:15:02Z")
    end

    test "are found in multi-line arrays too", %{updates: updates} do
      assert {:record, %{id: @tests, state: "pending", order: 3, name: "Run tests"}} in updates
    end

    test "map the runner's results to step conclusions", %{updates: updates} do
      assert {:record, last} =
               updates |> Enum.filter(&match?({:record, %{id: @tests}}, &1)) |> List.last()

      assert last.conclusion == "cancelled"
    end

    test "mark the job's own record, which isn't a step", %{updates: updates} do
      assert {:job, @job} in updates
      refute Enum.any?(updates, &match?({:record, %{id: @job}}, &1))
    end
  end

  test "garbage yields nothing, and doesn't crash" do
    assert parse("worker/Worker_garbage.log") == []
    assert WorkerLog.parse(:crypto.strong_rand_bytes(4096)) |> is_list()
  end

  test "feeding the log in arbitrary chunks gives the same updates" do
    raw = File.read!(fixture("worker/Worker_20261103-101500-utc.log"))
    whole = WorkerLog.parse(raw)

    chunks = for <<chunk::binary-size(97) <- raw>>, do: chunk
    rest = binary_part(raw, length(chunks) * 97, byte_size(raw) - length(chunks) * 97)

    {updates, parser} =
      Enum.reduce(chunks ++ [rest], {[], WorkerLog.new()}, fn chunk, {acc, p} ->
        {updates, p} = WorkerLog.feed(p, chunk)
        {acc ++ updates, p}
      end)

    {last, _} = WorkerLog.flush(parser)
    assert updates ++ last == whole
  end

  test "an entry is only parsed once the next one starts, or on flush" do
    {[], p} =
      WorkerLog.feed(WorkerLog.new(), ~s([2026-11-03 10:15:04Z INFO X] {"stepId":"#{@checkout}",))

    {[], p} = WorkerLog.feed(p, ~s(\n "result": "skipped"}\n))
    assert {[{:record, %{id: @checkout, conclusion: "skipped"}}], _} = WorkerLog.flush(p)
  end
end
