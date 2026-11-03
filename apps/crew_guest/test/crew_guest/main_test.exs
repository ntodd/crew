defmodule CrewGuest.MainTest do
  # Named processes and the fake system's application env: one at a time.
  use ExUnit.Case, async: false

  import CrewGuest.TestHelpers

  alias CrewGuest.{API, Config, FakeAPI, Main, Outbox}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:crew_guest, :fake_system, self())

    on_exit(fn ->
      Application.delete_env(:crew_guest, :fake_system)
      Application.delete_env(:crew_guest, :fake_system_fail)
    end)

    %{dir: dir}
  end

  defp config(api, dir, env \\ []) do
    %Config{
      mode: :local,
      vm_id: "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60",
      token: "t0ken",
      api_url: FakeAPI.url(api),
      runner_dir: Path.join(dir, "runner"),
      run_dir: Path.join(dir, "run"),
      runner_cmd: [fixture("stub-runner")],
      runner_env:
        [
          {"STUB_DELAY", "0.3"},
          {"STUB_WORKER_LOG", fixture("worker/Worker_20261103-101500-utc.log")}
        ] ++ env,
      payload_timeout_ms: 1_000,
      payload_retry_ms: 50,
      flush_timeout_ms: 3_000,
      metrics_interval_ms: 200
    }
  end

  defp boot(cfg) do
    client = API.from_config(cfg, on_stop: &Main.request_stop/0)
    start_supervised!({Outbox, name: Outbox, client: client})

    start_supervised!(
      {Main, config: cfg, system: CrewGuest.FakeSystem, client: client, outbox: Outbox}
    )
  end

  defp start_api(payload \\ payload()), do: start_supervised!({FakeAPI, payload: payload})

  test "runs a job from the payload to poweroff", %{dir: dir} do
    api = start_api()
    cfg = config(api, dir, [{"STUB_EXIT", "3"}])
    boot(cfg)

    pem = payload()["ca_pem"]
    assert_receive {:system, :setup_network}
    assert_receive {:system, :resize_root}
    assert_receive {:system, {:install_ca, ^pem}}
    assert_receive {:system, :configure_docker}
    assert_receive {:system, :notify_ready}
    assert_receive {:system, :start_docker}
    assert_receive {:system, {:prepare_runner, ["policy.json", "jit", "guest.env"]}}
    assert_receive {:system, :poweroff}, 15_000

    assert [%{auth: "Bearer t0ken"}] = FakeAPI.requests(api, "/v1/payload")
    assert FakeAPI.states(api) == ~w(runner_listening job_started job_finished)
    assert List.last(FakeAPI.delivered(api, "/v1/state")).cast.detail == "exit_code=3"

    texts = FakeAPI.log_texts(api)

    assert texts == [
             "Current runner version: '2.329.0'",
             "Runner name: 'crew-stub'",
             "##[group]Run actions/checkout@v4",
             "Syncing repository: ntodd/crew",
             "##[endgroup]",
             "##[group]Run make test",
             "ok 1 - first",
             "ok 2 - second",
             "Process completed with exit code 3."
           ]

    refs = api |> FakeAPI.log_lines() |> Enum.map(& &1.step_ref) |> Enum.dedup()

    assert refs == [
             "6c5d4e3f-2222-4222-8222-000000000001",
             "7f1c2a0e-5b8d-4c3e-9a1f-2d4e6b8c0a13",
             "8e2d3b1f-6c9e-4d4f-8b2a-3e5f7c9d1b24"
           ]

    steps = FakeAPI.last_steps(api)
    assert Enum.map(steps, & &1.name) == ["Step 1", "Run actions/checkout@v4", "Run tests"]
    assert Enum.all?(steps, &(&1.status == "completed"))
    assert Enum.map(steps, & &1.ref) == refs

    assert FakeAPI.delivered(api, "/v1/metrics") != []

    # What the job-started hook reads, and the JIT config gone once read.
    policy = cfg.run_dir |> Path.join("policy.json") |> File.read!() |> Jason.decode!()
    assert policy == payload()["policy"]
    env = File.read!(Path.join(cfg.run_dir, "guest.env"))
    assert env =~ "CREW_API='#{cfg.api_url}'"
    assert env =~ "CREW_TOKEN='t0ken'"
    refute File.exists?(Path.join(cfg.run_dir, "jit"))
  end

  test "a payload that never comes powers off without starting the runner", %{dir: dir} do
    api = start_api()
    FakeAPI.respond(api, "/v1/payload", [:drop])
    boot(config(api, dir))

    assert_receive {:system, :poweroff}, 5_000
    assert length(FakeAPI.requests(api, "/v1/payload")) > 3
    refute_received {:system, {:prepare_runner, _}}
  end

  test "a payload that's already been fetched powers off at once", %{dir: dir} do
    api = start_api(nil)
    boot(config(api, dir))

    assert_receive {:system, :poweroff}, 1_000
    assert [%{status: 410}] = FakeAPI.requests(api, "/v1/payload")
  end

  test "a JIT config that would let the runner update itself is refused", %{dir: dir} do
    api = start_api(payload(%{"jit_config" => jit_config(%{"DisableUpdate" => false})}))
    boot(config(api, dir))

    assert_receive {:system, :poweroff}, 5_000
    refute_received {:system, {:prepare_runner, _}}
    assert FakeAPI.states(api) == []
    assert [line] = FakeAPI.log_texts(api)
    assert line =~ "update_not_disabled"
  end

  test "a stop from the control poll stops the runner, flushes and powers off",
       %{dir: dir} do
    api = start_api()
    boot(config(api, dir, [{"STUB_HANG", "1"}]))

    eventually(fn -> FakeAPI.log_texts(api) |> Enum.member?("ok 2 - second") end, 10_000)
    FakeAPI.request_stop(api)

    assert_receive {:system, :poweroff}, 10_000
    assert "stub-runner: got SIGTERM" in FakeAPI.log_texts(api)

    # The stop also answers the state post, which is fine.
    assert "job_finished" in Enum.map(FakeAPI.requests(api, "/v1/state"), & &1.cast.state)
  end

  test "a stop in any other response stops too", %{dir: dir} do
    api = start_api()
    FakeAPI.respond(api, "/v1/state", [{200, %{"stop" => true}}])
    boot(config(api, dir, [{"STUB_HANG", "1"}]))

    assert_receive {:system, :poweroff}, 10_000
    assert [%{cast: %{state: "runner_listening"}} | _] = FakeAPI.requests(api, "/v1/state")
  end

  test "if the job's processes fail, it still flushes and powers off", %{dir: dir} do
    api = start_api()
    main = boot(config(api, dir, [{"STUB_HANG", "1"}]))

    eventually(fn -> "job_started" in FakeAPI.states(api) end, 5_000)
    %{job: job} = :sys.get_state(main)
    Process.exit(job, :kill)

    assert_receive {:system, :poweroff}, 10_000
    assert Enum.any?(FakeAPI.log_texts(api), &(&1 =~ "the job's processes failed"))
  end

  test "a failed OS step is reported, and the job still runs", %{dir: dir} do
    Application.put_env(:crew_guest, :fake_system_fail, [:start_docker])
    api = start_api()
    boot(config(api, dir))

    assert_receive {:system, :poweroff}, 15_000
    assert [first | _] = FakeAPI.log_texts(api)
    assert first =~ "starting Docker failed"
    assert FakeAPI.states(api) == ~w(runner_listening job_started job_finished)
  end
end
