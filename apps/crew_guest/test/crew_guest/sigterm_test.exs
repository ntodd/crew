defmodule CrewGuest.SigtermTest do
  # A real SIGTERM to a real crew-guest: a peer node starts the application
  # in local mode, as the release does, against the fake guest API.
  use ExUnit.Case, async: false

  import CrewGuest.TestHelpers

  alias CrewGuest.FakeAPI

  @moduletag :tmp_dir

  defp start_guest(api, dir, env \\ []) do
    env =
      [
        {"CREW_GUEST_MODE", "local"},
        {"CREW_GUEST_VM", "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60"},
        {"CREW_GUEST_TOKEN", "t0ken"},
        {"CREW_GUEST_API", FakeAPI.url(api)},
        {"CREW_GUEST_RUNNER_DIR", Path.join(dir, "runner")},
        {"CREW_GUEST_RUNNER_CMD", fixture("stub-runner")}
      ] ++ env

    # The node doesn't log. Its default handler writes to the control
    # connection (the node's stdout), now and then fails there, and the
    # node's report of that comes through here as stray output. To see its
    # logs, swap the last four args for `-logger level warning`.
    args =
      Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++
        [~c"-kernel", ~c"logger", ~c"[{handler,default,undefined}]"] ++
        [~c"-logger", ~c"default_handler", ~c"false"]

    {:ok, peer, _node} =
      :peer.start(%{
        connection: :standard_io,
        args: args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      })

    os_pid = :peer.call(peer, System, :pid, [])
    on_exit(fn -> System.cmd("kill", ["-KILL", os_pid], stderr_to_stdout: true) end)
    {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:crew_guest], 15_000)
    %{peer: peer, os_pid: os_pid}
  end

  # How long the node takes to exit after a SIGTERM.
  defp sigterm(%{peer: peer, os_pid: os_pid}) do
    ref = Process.monitor(peer)
    t0 = System.monotonic_time(:millisecond)
    {_, 0} = System.cmd("kill", ["-TERM", os_pid])
    assert_receive {:DOWN, ^ref, :process, ^peer, _reason}, 15_000
    System.monotonic_time(:millisecond) - t0
  end

  test "while it waits for its payload, SIGTERM ends it at once", %{tmp_dir: dir} do
    api = start_supervised!({FakeAPI, payload: payload()})
    FakeAPI.respond(api, "/v1/payload", [{503, nil}])
    guest = start_guest(api, dir)
    eventually(fn -> length(FakeAPI.requests(api, "/v1/payload")) >= 2 end)

    ms = sigterm(guest)
    assert ms < 1_000, "took #{ms} ms"
  end

  test "mid-job, SIGTERM stops the runner and reports job_finished and the last lines first",
       %{tmp_dir: dir} do
    api = start_supervised!({FakeAPI, payload: payload()})
    guest = start_guest(api, dir, [{"STUB_HANG", "1"}, {"STUB_DELAY", "0.1"}])
    eventually(fn -> "ok 2 - second" in FakeAPI.log_texts(api) end, 10_000)

    ms = sigterm(guest)
    assert ms < 2_000, "took #{ms} ms"
    assert FakeAPI.states(api) == ~w(runner_listening job_started job_finished)
    assert List.last(FakeAPI.delivered(api, "/v1/state")).cast.detail == "exit_code=143"
    assert "stub-runner: got SIGTERM" in FakeAPI.log_texts(api)
  end
end
