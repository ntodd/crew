defmodule CrewGuest.OutboxTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{FakeAPI, Outbox}

  setup do
    %{api: start_supervised!(FakeAPI)}
  end

  defp start_outbox(api, opts \\ []) do
    start_supervised!({Outbox, Keyword.merge([client: client(api)], opts)})
  end

  defp lines(range, size \\ 10) do
    for i <- range, do: %{t: 1_000 + i, step_ref: "s1", text: pad("line #{i}", size)}
  end

  defp pad(text, size), do: String.pad_trailing(text, size, ".")

  describe "states" do
    test "each state is sent once, in order, and never backwards", %{api: api} do
      o = start_outbox(api)
      before = System.system_time(:millisecond)

      Outbox.state(o, "runner_listening")
      Outbox.state(o, "runner_listening")
      Outbox.state(o, "job_started")
      Outbox.state(o, "runner_listening")
      Outbox.state(o, "job_finished", "exit_code=3")

      eventually(fn -> length(FakeAPI.states(api)) == 3 end)
      assert FakeAPI.states(api) == ~w(runner_listening job_started job_finished)

      [_, _, finished] = FakeAPI.delivered(api, "/v1/state")
      assert finished.cast.detail == "exit_code=3"
      assert finished.cast.at >= before
      Outbox.flush(o, 1_000)
      assert length(FakeAPI.requests(api, "/v1/state")) == 3
    end

    test "a state is retried until it's delivered", %{api: api} do
      FakeAPI.respond(api, "/v1/state", [:drop, {503, nil}, {204, nil}])
      o = start_outbox(api, backoff_min_ms: 10, backoff_max_ms: 20)

      Outbox.state(o, "runner_listening")
      eventually(fn -> FakeAPI.states(api) == ["runner_listening"] end)
      assert length(FakeAPI.requests(api, "/v1/state")) == 3
    end

    test "a state the agent refuses is dropped, and the next still goes", %{api: api} do
      FakeAPI.respond(api, "/v1/state", [{409, nil}, {204, nil}])
      o = start_outbox(api)

      Outbox.state(o, "runner_listening")
      Outbox.state(o, "job_started")
      eventually(fn -> FakeAPI.states(api) == ["job_started"] end)
    end
  end

  describe "logs" do
    test "lines go out as NDJSON the agent accepts", %{api: api} do
      o = start_outbox(api)
      Outbox.log(o, [%{t: 1, step_ref: "s1", text: "a"}, %{t: 2, step_ref: nil, text: "b"}])

      eventually(fn -> FakeAPI.log_texts(api) == ["a", "b"] end)
      assert [%{cast: %{skipped: 0, lines: [first, second]}}] = FakeAPI.requests(api, "/v1/log")
      assert first.step_ref == "s1" and first.t == 1
      assert second.step_ref == nil
    end

    test "a batch waits for the 250 ms tick", %{api: api} do
      o = start_outbox(api)
      Outbox.log(o, [%{t: 1, step_ref: nil, text: "a"}])
      Outbox.log(o, [%{t: 2, step_ref: nil, text: "b"}])

      eventually(fn -> FakeAPI.log_texts(api) == ["a", "b"] end, 1_000)
      assert length(FakeAPI.requests(api, "/v1/log")) == 1
    end

    test "64 KiB of lines go out without waiting for the tick", %{api: api} do
      o = start_outbox(api, batch_ms: 60_000)
      Outbox.log(o, lines(1..70, 1_000))

      eventually(fn -> FakeAPI.requests(api, "/v1/log") != [] end, 1_000)
    end

    test "a request is at most 1 MiB, and requests at most 8 a second", %{api: api} do
      record_request_starts(api)
      o = start_outbox(api)
      sent = lines(1..96, 32_768)
      Outbox.log(o, sent)

      eventually(fn -> length(FakeAPI.log_lines(api)) == 96 end)
      reqs = FakeAPI.requests(api, "/v1/log")
      assert length(reqs) >= 3
      assert Enum.all?(reqs, &(&1.bytes <= 1_048_576))
      assert FakeAPI.log_texts(api) == Enum.map(sent, & &1.text)

      # The Outbox starts requests 125 ms apart. The client sees each start
      # a moment later, but connecting and uploading come after, so they
      # can't eat into the gap the way they did at the server.
      starts = request_starts("/v1/log")
      assert length(starts) == length(reqs)
      gaps = Enum.chunk_every(starts, 2, 1, :discard)
      assert Enum.all?(gaps, fn [a, b] -> b - a >= 100 end)
    end

    test "text is cleaned before it's sent", %{api: api} do
      o = start_outbox(api)
      Outbox.log(o, [%{t: 1, step_ref: nil, text: <<"a", 0xFF, 0, "b">>}])
      Outbox.log(o, [%{t: 2, step_ref: nil, text: String.duplicate("é", 40_000)}])

      eventually(fn -> length(FakeAPI.log_lines(api)) == 2 end)
      assert [%{cast: %{skipped: 0}}] = FakeAPI.requests(api, "/v1/log")
      [_, long] = FakeAPI.log_lines(api)
      assert byte_size(long.text) <= 65_536
    end

    test "after a 413 no more logs are sent, but states still are", %{api: api} do
      FakeAPI.respond(api, "/v1/log", [{413, nil}])
      o = start_outbox(api)

      Outbox.log(o, [%{t: 1, step_ref: nil, text: "a"}])
      eventually(fn -> FakeAPI.requests(api, "/v1/log") != [] end)
      Outbox.log(o, [%{t: 2, step_ref: nil, text: "b"}])
      Outbox.state(o, "job_finished")

      assert :ok = Outbox.flush(o, 1_000)
      assert length(FakeAPI.requests(api, "/v1/log")) == 1
      assert FakeAPI.states(api) == ["job_finished"]
    end

    test "while the API is down, lines are kept and then delivered in order", %{api: api} do
      FakeAPI.set_down(api, true)
      o = start_outbox(api, backoff_min_ms: 20, backoff_max_ms: 50)

      sent = lines(1..100)
      for chunk <- Enum.chunk_every(sent, 10), do: Outbox.log(o, chunk)
      eventually(fn -> length(FakeAPI.requests(api, "/v1/log")) >= 2 end)

      FakeAPI.set_down(api, false)
      eventually(fn -> length(FakeAPI.log_lines(api)) == 100 end)
      assert FakeAPI.log_texts(api) == Enum.map(sent, & &1.text)
    end

    test "past the buffer the oldest lines are dropped, with one marker counting them",
         %{api: api} do
      FakeAPI.set_down(api, true)
      o = start_outbox(api, buffer_bytes: 10_000, backoff_min_ms: 20, backoff_max_ms: 50)

      # The first line is in flight when the API goes down, and is kept.
      Outbox.log(o, lines(1..1, 100))
      eventually(fn -> FakeAPI.requests(api, "/v1/log") != [] end)
      sent = lines(2..300, 100)
      for chunk <- Enum.chunk_every(sent, 20), do: Outbox.log(o, chunk)

      FakeAPI.set_down(api, false)
      assert :ok = Outbox.flush(o, 3_000)

      texts = FakeAPI.log_texts(api)
      assert [marker] = Enum.filter(texts, &(&1 =~ "log lines dropped"))
      [dropped] = Regex.run(~r/(\d+) log lines dropped/, marker, capture: :all_but_first)
      kept = Enum.reject(texts, &(&1 == marker))

      assert hd(kept) == pad("line 1", 100)
      assert length(kept) + String.to_integer(dropped) == 300
      # What's kept after the gap is the newest lines, in order.
      assert List.last(kept) == pad("line 300", 100)
      assert Enum.drop(kept, 1) == Enum.take(Enum.map(sent, & &1.text), -(length(kept) - 1))
    end

    test "a batch still failing after the give-up window is dropped and counted",
         %{api: api} do
      FakeAPI.set_down(api, true)
      o = start_outbox(api, give_up_ms: 200, backoff_min_ms: 20, backoff_max_ms: 50)

      Outbox.log(o, [%{t: 1, step_ref: nil, text: "old"}])
      # The first attempt waits for the batch tick, then 200 ms of failures.
      Process.sleep(900)
      FakeAPI.set_down(api, false)
      Outbox.log(o, [%{t: 2, step_ref: nil, text: "new"}])

      assert :ok = Outbox.flush(o, 2_000)
      assert [marker, "new"] = FakeAPI.log_texts(api)
      assert marker =~ "1 log lines dropped"
    end
  end

  describe "steps" do
    @step %{
      ref: "s1",
      name: "Run tests",
      number: 1,
      status: "in_progress",
      started_at: 1,
      completed_at: nil,
      conclusion: nil
    }

    test "only the latest snapshot goes, at most 2 a second", %{api: api} do
      record_request_starts(api)
      o = start_outbox(api)

      for n <- 1..10 do
        Outbox.steps(o, [%{@step | number: n}])
        Process.sleep(20)
      end

      eventually(fn -> match?([%{number: 10}], FakeAPI.last_steps(api)) end)
      reqs = FakeAPI.requests(api, "/v1/steps")
      assert length(reqs) <= 3
      # Requests start 500 ms apart, as the client sees them.
      starts = request_starts("/v1/steps")
      assert length(starts) == length(reqs)
      gaps = Enum.chunk_every(starts, 2, 1, :discard)
      assert Enum.all?(gaps, fn [a, b] -> b - a >= 400 end)
    end

    test "a body over 256 KiB is cut down to fit", %{api: api} do
      o = start_outbox(api)

      steps =
        for n <- 1..1000,
            do: %{@step | ref: "step-#{n}", number: n, name: String.duplicate("n", 500)}

      Outbox.steps(o, steps)
      eventually(fn -> FakeAPI.last_steps(api) != [] end)
      [req] = FakeAPI.requests(api, "/v1/steps")
      assert req.bytes <= 262_144
      assert is_list(req.cast)
    end
  end

  describe "flush/2" do
    test "returns as soon as everything is delivered", %{api: api} do
      o = start_outbox(api, batch_ms: 60_000)
      Outbox.log(o, [%{t: 1, step_ref: nil, text: "a"}])
      Outbox.state(o, "job_finished")
      Outbox.steps(o, [@step])

      {us, :ok} = :timer.tc(fn -> Outbox.flush(o, 5_000) end)
      assert us < 1_000_000
      assert FakeAPI.log_texts(api) == ["a"]
      assert FakeAPI.states(api) == ["job_finished"]
      assert [_] = FakeAPI.last_steps(api)
    end

    test "gives up at the deadline", %{api: api} do
      FakeAPI.set_down(api, true)
      o = start_outbox(api)
      Outbox.log(o, [%{t: 1, step_ref: nil, text: "a"}])

      {us, result} = :timer.tc(fn -> Outbox.flush(o, 300) end)
      assert result == {:error, :timeout}
      assert us < 1_000_000
    end
  end

  test "{\"stop\": true} in a response is reported", %{api: api} do
    FakeAPI.request_stop(api)
    o = start_outbox(api)
    Outbox.state(o, "runner_listening")
    assert_receive :stop_requested, 1_000
  end
end
