defmodule CrewGuest.ControlTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{Control, FakeAPI}

  setup do
    %{api: start_supervised!(FakeAPI)}
  end

  test "keeps one poll open, and reports a stop", %{api: api} do
    pid = start_supervised!({Control, client: client(api)})
    ref = Process.monitor(pid)

    eventually(fn -> length(FakeAPI.requests(api, "/v1/control")) == 1 end)
    refute_received :stop_requested

    FakeAPI.request_stop(api)
    assert_receive :stop_requested, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "polls again after a 204", %{api: api} do
    FakeAPI.respond(api, "/v1/control", [{204, nil}, {204, nil}, {200, %{"stop" => true}}])
    start_supervised!({Control, client: client(api)})

    assert_receive :stop_requested, 1_000
    assert length(FakeAPI.requests(api, "/v1/control")) == 3
  end

  test "backs off and retries when the poll fails", %{api: api} do
    FakeAPI.respond(api, "/v1/control", [:drop, {500, nil}, {200, %{"stop" => true}}])
    start_supervised!({Control, client: client(api), backoff_min_ms: 10, backoff_max_ms: 20})

    assert_receive :stop_requested, 2_000
    assert length(FakeAPI.requests(api, "/v1/control")) == 3
  end
end
