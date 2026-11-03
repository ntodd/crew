defmodule CrewGuest.APITest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{API, FakeAPI}

  setup do
    api = start_supervised!({FakeAPI, payload: payload()})
    %{api: api, client: client(api)}
  end

  test "fetches the payload once with the bearer token", %{api: api, client: client} do
    assert {:ok, %{"jit_config" => _, "policy" => %{"fork_prs" => "refuse"}}} =
             API.get_payload(client)

    assert [%{auth: "Bearer t0ken"}] = FakeAPI.requests(api, "/v1/payload")
    assert {:error, {:status, 410}} = API.get_payload(client)
  end

  test "a payload that isn't a JSON object is an error", %{api: api, client: client} do
    FakeAPI.respond(api, "/v1/payload", [{200, ["not", "an", "object"]}])
    assert {:error, :bad_payload} = API.get_payload(client)
  end

  test "posts bodies as JSON, and logs as NDJSON", %{api: api, client: client} do
    assert {:ok, 204} = API.post_state(client, %{state: "runner_listening", at: 1})
    assert {:ok, 204} = API.post_log(client, [~s({"t":1,"step_ref":null,"text":"hi"}), "\n"])

    assert [%{json: %{"state" => "runner_listening"}, content_type: "application/json"}] =
             FakeAPI.requests(api, "/v1/state")

    assert [%{content_type: "application/x-ndjson", cast: %{lines: [%{text: "hi"}]}}] =
             FakeAPI.requests(api, "/v1/log")
  end

  test "{\"stop\": true} in any response asks for a stop", %{api: api, client: client} do
    for path <- ~w(/v1/state /v1/steps /v1/log /v1/metrics) do
      FakeAPI.respond(api, path, [{200, %{"stop" => true}}])
    end

    assert {:ok, 200} = API.post_state(client, %{state: "job_started", at: 1})
    assert_received :stop_requested
    assert {:ok, 200} = API.post_steps(client, %{steps: []})
    assert_received :stop_requested
    assert {:ok, 200} = API.post_log(client, "")
    assert_received :stop_requested
    assert {:ok, 200} = API.post_metrics(client, %{t: 1})
    assert_received :stop_requested
  end

  test "other statuses are errors with the status", %{api: api, client: client} do
    FakeAPI.respond(api, "/v1/log", [{413, nil}])
    assert {:error, {:status, 413}} = API.post_log(client, "x\n")
    refute_received :stop_requested
  end

  test "a dropped connection is a transport error", %{api: api, client: client} do
    FakeAPI.set_down(api, true)
    assert {:error, %{__exception__: true}} = API.post_state(client, %{state: "job_started"})
  end

  test "an unreachable API is a transport error" do
    client = API.new(base_url: "http://127.0.0.1:1", token: "t")
    assert {:error, %{__exception__: true}} = API.post_state(client, %{state: "job_started"})
  end

  describe "the control long poll" do
    test "answers :stop once a stop is requested", %{api: api, client: client} do
      task = Task.async(fn -> API.get_control(client) end)
      eventually(fn -> FakeAPI.requests(api, "/v1/control") != [] end)
      FakeAPI.request_stop(api)
      assert {:ok, :stop} = Task.await(task)
      assert_received :stop_requested
    end

    test "answers :continue on 204", %{api: api, client: client} do
      FakeAPI.respond(api, "/v1/control", [{204, nil}])
      assert {:ok, :continue} = API.get_control(client)
    end
  end
end
