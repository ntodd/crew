defmodule CrewGuest.RunnerTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.{Config, Runner}

  @moduletag :tmp_dir

  defp config(dir, env, cmd \\ [fixture("stub-runner")]) do
    %Config{
      mode: :local,
      vm_id: "vm",
      token: "t",
      api_url: "http://127.0.0.1:1",
      runner_dir: dir,
      run_dir: Path.join(dir, ".crew"),
      runner_cmd: cmd,
      runner_env: [{"STUB_DELAY", "0.05"} | env]
    }
  end

  defp start_runner(cfg) do
    jit = Path.join(cfg.run_dir, "jit")
    File.mkdir_p!(cfg.run_dir)
    File.write!(jit, "the-jit-config")
    test = self()

    pid =
      start_supervised!(
        {Runner,
         config: cfg,
         system: CrewGuest.System.Local,
         jit_file: jit,
         on_state: &send(test, {:state, &1}),
         on_exit: &send(test, {:exit, &1})}
      )

    {pid, jit}
  end

  test "runs the runner with its JIT config, deleting the file once it's read",
       %{tmp_dir: dir} do
    out = Path.join(dir, "jit.out")
    {_pid, jit} = start_runner(config(dir, [{"STUB_JIT_OUT", out}]))

    assert_receive {:exit, 0}, 5_000
    assert File.read!(out) == "the-jit-config"
    refute File.exists?(jit)
  end

  test "reports runner_listening and job_started from what the runner prints",
       %{tmp_dir: dir} do
    start_runner(config(dir, []))
    assert_receive {:state, "runner_listening"}, 5_000
    assert_receive {:state, "job_started"}, 5_000
    assert_receive {:exit, 0}, 5_000
  end

  test "reports the runner's exit code", %{tmp_dir: dir} do
    start_runner(config(dir, [{"STUB_EXIT", "3"}]))
    assert_receive {:exit, 3}, 5_000
  end

  test "stop/1 sends the runner SIGTERM", %{tmp_dir: dir} do
    {pid, _jit} = start_runner(config(dir, [{"STUB_HANG", "1"}]))
    assert_receive {:state, "job_started"}, 5_000
    Process.sleep(300)

    :ok = Runner.stop(pid)
    assert_receive {:exit, 143}, 5_000
  end

  test "stop/1 sends SIGTERM once, however often it's called", %{tmp_dir: dir} do
    {pid, _jit} = start_runner(config(dir, [{"STUB_HANG", "1"}, {"STUB_CANCEL", "0.5"}]))
    listener = stub_listener(dir)

    :ok = Runner.stop(pid)
    eventually(fn -> stub_page(dir) =~ "got SIGTERM" end)
    # run.sh has dropped its trap: another SIGTERM would kill it now.
    :ok = Runner.stop(pid)

    assert_receive {:exit, 143}, 5_000
    assert stub_page(dir) =~ "stub-runner: cancelled"
    assert stub_page(dir) =~ "stub-runner: done waiting"
    eventually(fn -> not os_alive?(listener) end, 2_000)
  end

  test "kill/1 SIGKILLs the runner and every process group it started", %{tmp_dir: dir} do
    {pid, _jit} = start_runner(config(dir, [{"STUB_HANG", "ignore"}]))
    listener = stub_listener(dir)

    :ok = Runner.stop(pid)
    eventually(fn -> stub_page(dir) =~ "ignoring SIGINT" end)
    :ok = Runner.kill(pid)

    assert_receive {:exit, 137}, 2_000
    eventually(fn -> not os_alive?(listener) end, 2_000)
  end

  test "kill_targets/3: the runner's descendants and their groups, never crew-guest's" do
    ps = """
        1     0     1
      100     1   100
      101   100   100
      200   101   200
      201   200   201
      202   201   201
      203   202   100
      300   101   300
    """

    # 100 is crew-guest (and its group), 200 the runner, 201 run.sh's
    # listener in its own group (set -m), 300 some other port.
    assert Runner.kill_targets(ps, 200, 100) == {[200, 201], [200, 201, 202, 203]}
  end

  test "a runner that can't start is an exit", %{tmp_dir: dir} do
    start_runner(config(dir, [], [Path.join(dir, "no-such-runner")]))
    assert_receive {:exit, code}, 5_000
    assert code != 0
  end
end
