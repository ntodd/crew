defmodule CrewGuest.ConformanceTest do
  @moduledoc """
  Conformance mode (§11.6): a payload with a `conformance` object runs
  the image's fixed check script instead of the runner. The script's path
  is crew-guest's own (`Config.conformance_cmd`), never the payload's,
  and it's given only the path of the checked object.
  """
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
      conformance_cmd: fixture("stub-conformance"),
      runner_env: [{"STUB_CONFORMANCE_OUT", Path.join(dir, "seen.json")} | env],
      payload_timeout_ms: 1_000,
      payload_retry_ms: 50,
      flush_timeout_ms: 3_000,
      sigterm_timeout_ms: 1_000,
      flush_reserve_ms: 500,
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

  # The example JIT config isn't one GitHub issued: conformance mode never
  # looks at it.
  defp conformance_payload(conformance) do
    payload(%{"jit_config" => Base.encode64("not a jit config"), "conformance" => conformance})
  end

  test "runs the image's check instead of the runner, reports its lines, then powers off",
       %{dir: dir} do
    api =
      start_supervised!({FakeAPI, payload: conformance_payload(%{"checks" => ["sizing", "dns"]})})

    cfg = config(api, dir)
    boot(cfg)

    pem = payload()["ca_pem"]
    assert_receive {:system, {:install_ca, ^pem}}
    assert_receive {:system, :configure_docker}
    assert_receive {:system, :start_docker}
    assert_receive {:system, {:prepare_conformance, ["conformance.json"]}}
    assert_receive {:system, :poweroff}, 10_000
    refute_received {:system, {:prepare_runner, _}}

    assert FakeAPI.states(api) == ~w(runner_listening job_finished)
    [listening, finished] = FakeAPI.delivered(api, "/v1/state")
    assert listening.cast.detail == "conformance"
    assert finished.cast.detail == "exit_code=0"

    texts = FakeAPI.log_texts(api)
    # Only the object's path: nothing else from the payload reaches it.
    assert "stub-conformance: 1 argument(s)" in texts
    assert "crew-conformance: sizing ok stub" in texts
    assert "crew-conformance: dns ok stub" in texts
    assert Enum.uniq(Enum.map(FakeAPI.log_lines(api), & &1.step_ref)) == ["conformance"]

    # What the script reads: the checked object and the VM's size.
    seen = dir |> Path.join("seen.json") |> File.read!() |> Jason.decode!()
    assert seen["checks"] == ["sizing", "dns"]
    assert seen["size"] == payload()["size"]
    refute Map.has_key?(seen, "jit_config")
    refute File.exists?(Path.join(cfg.run_dir, "jit"))
  end

  test "a conformance object that doesn't validate runs nothing and powers off", %{dir: dir} do
    bad = %{"checks" => ["sizing"], "script" => "/bin/sh -c reboot"}
    api = start_supervised!({FakeAPI, payload: conformance_payload(bad)})
    boot(config(api, dir))

    assert_receive {:system, :poweroff}, 5_000
    refute_received {:system, {:prepare_conformance, _}}
    refute_received {:system, {:prepare_runner, _}}
    assert FakeAPI.states(api) == []
    assert [line] = FakeAPI.log_texts(api)
    assert line =~ "refusing the conformance payload"
    refute File.exists?(Path.join(dir, "seen.json"))
  end

  test "a stop ends the check with SIGTERM, then flushes and powers off", %{dir: dir} do
    payload = conformance_payload(%{"checks" => ["sizing"], "hold_s" => 60})
    api = start_supervised!({FakeAPI, payload: payload})
    boot(config(api, dir))

    eventually(fn -> "crew-conformance: sizing ok stub" in FakeAPI.log_texts(api) end)
    t0 = System.monotonic_time(:millisecond)
    FakeAPI.request_stop(api)

    assert_receive {:system, :poweroff}, 10_000
    assert System.monotonic_time(:millisecond) - t0 < 3_000
    assert "stub-conformance: got SIGTERM" in FakeAPI.log_texts(api)
    assert List.last(FakeAPI.delivered(api, "/v1/state")).cast.detail == "exit_code=143"
  end

  test "the check's exit code is reported", %{dir: dir} do
    api = start_supervised!({FakeAPI, payload: conformance_payload(%{"checks" => []})})
    boot(config(api, dir, [{"STUB_CONFORMANCE_EXIT", "3"}]))

    assert_receive {:system, :poweroff}, 10_000
    assert List.last(FakeAPI.delivered(api, "/v1/state")).cast.detail == "exit_code=3"
  end

  test "the script's path is crew-guest's own" do
    assert %Config{conformance_cmd: "/opt/crew/conformance/check"} =
             struct!(Config,
               mode: :vm,
               vm_id: "v",
               token: "t",
               api_url: "http://10.199.0.1:7777",
               runner_dir: "/r",
               runner_cmd: ["/r/run.sh"],
               run_dir: "/run/crew"
             )

    # Nothing in the environment or the command line moves it.
    {:ok, cfg} =
      Config.load(
        cmdline:
          "crew.vm=v crew.token=t crew.api=http://10.199.0.1:7777 crew.conformance=/bin/sh",
        env: %{"CREW_GUEST_CONFORMANCE_CMD" => "/bin/sh"}
      )

    assert cfg.conformance_cmd == "/opt/crew/conformance/check"
  end
end
