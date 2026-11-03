defmodule CrewGuest.SessionTest do
  use ExUnit.Case, async: false

  import CrewGuest.TestHelpers

  alias CrewGuest.{Config, FakeAPI, Session}

  @moduletag :tmp_dir

  setup do
    Application.put_env(:crew_guest, :fake_system, self())
    on_exit(fn -> Application.delete_env(:crew_guest, :fake_system) end)
  end

  test "boots from a config, and a stop in any response reaches the boot sequence",
       %{tmp_dir: dir} do
    api = start_supervised!({FakeAPI, payload: payload()})

    {:ok, cfg} =
      Config.load(
        cmdline: nil,
        env: %{
          "CREW_GUEST_MODE" => "local",
          "CREW_GUEST_VM" => "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60",
          "CREW_GUEST_TOKEN" => "t0ken",
          "CREW_GUEST_API" => FakeAPI.url(api),
          "CREW_GUEST_RUNNER_DIR" => Path.join(dir, "runner"),
          "CREW_GUEST_RUNNER_CMD" => fixture("stub-runner")
        }
      )

    cfg = %{cfg | runner_env: [{"STUB_HANG", "1"}, {"STUB_DELAY", "0.1"}]}
    start_supervised!({Session, config: cfg, system: CrewGuest.FakeSystem})

    # The stub traps SIGTERM once its steps are done.
    eventually(fn -> "ok 2 - second" in FakeAPI.log_texts(api) end, 5_000)
    FakeAPI.request_stop(api)

    assert_receive {:system, :poweroff}, 12_000
    assert "stub-runner: got SIGTERM" in FakeAPI.log_texts(api)
  end

  test "the application starts no session in tests" do
    refute Process.whereis(Session)
    assert Process.whereis(CrewGuest.Finch)
  end
end
