defmodule CrewGuest.Runner do
  @moduledoc """
  Runs and supervises the runner through a Port (§13.5 steps 8 and 9).

  The Port runs `priv/start-runner`, which reads the JIT config from its
  file, deletes the file and execs the system's runner command with
  `--jitconfig <config>`. The runner keeps the wrapper's pid, so `stop/1`'s
  SIGTERM reaches it.

  What the runner prints is logged (it's the listener's status, never job
  output) and watched for two states: `Listening for Jobs` is
  `runner_listening`, and `Running job:` (the listener handing the job to a
  worker) is `job_started`. When the runner exits, `:on_exit` gets its exit
  status (128 + n for signal n).
  """

  use GenServer, restart: :temporary

  require Logger

  @max_logged 1_024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Sends the runner SIGTERM."
  def stop(server), do: GenServer.call(server, :stop)

  @impl true
  def init(opts) do
    cfg = Keyword.fetch!(opts, :config)
    system = Keyword.fetch!(opts, :system)
    wrapper = Application.app_dir(:crew_guest, "priv/start-runner")
    args = [wrapper, Keyword.fetch!(opts, :jit_file) | system.runner_command(cfg)]

    env =
      [{"RUNNER_MANUALLY_TRAP_SIG", "1"} | cfg.runner_env]
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      # The runner mustn't be able to talk to systemd as crew-guest.
      |> Kernel.++([{~c"NOTIFY_SOCKET", false}])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 16_384},
        {:args, args},
        {:cd, cfg.runner_dir},
        {:env, env}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Logger.info("crew-guest: started the runner (pid #{os_pid})")

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       buf: "",
       on_state: Keyword.fetch!(opts, :on_state),
       on_exit: Keyword.fetch!(opts, :on_exit)
     }}
  end

  @impl true
  def handle_call(:stop, _from, s) do
    Logger.info("crew-guest: sending the runner SIGTERM")
    System.cmd("kill", ["-TERM", Integer.to_string(s.os_pid)], stderr_to_stdout: true)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = s) do
    # A very long line: only its start matters.
    buf = if byte_size(s.buf) < @max_logged, do: s.buf <> part, else: s.buf
    {:noreply, %{s | buf: buf}}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = s) do
    output(s.buf <> part, s)
    {:noreply, %{s | buf: ""}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Logger.info("crew-guest: the runner exited with status #{status}")
    s.on_exit.(status)
    {:stop, :normal, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp output(line, s) do
    Logger.info("runner: " <> String.slice(line, 0, @max_logged))

    cond do
      String.contains?(line, "Listening for Jobs") -> s.on_state.("runner_listening")
      String.contains?(line, "Running job:") -> s.on_state.("job_started")
      true -> :ok
    end
  end
end
