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

  test "a runner that can't start is an exit", %{tmp_dir: dir} do
    start_runner(config(dir, [], [Path.join(dir, "no-such-runner")]))
    assert_receive {:exit, code}, 5_000
    assert code != 0
  end
end
