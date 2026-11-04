defmodule CrewGuest.Runner do
  @moduledoc """
  Runs and supervises the runner through a Port (§13.5 steps 8 and 9).

  The Port runs `priv/start-runner`, which reads the JIT config from its
  file, deletes the file and execs the system's runner command with
  `--jitconfig <config>`. The runner keeps the wrapper's pid, so `stop/1`'s
  SIGTERM reaches it.

  **Stopping it** (`RUNNER_MANUALLY_TRAP_SIG`): run.sh runs the listener in
  its own process group, passes the first SIGTERM on to that group as
  SIGINT, then drops its trap and waits for the listener's last output. A
  second SIGTERM would kill it in that wait, so `stop/1` sends one, ever.
  `kill/1` is for a runner that's still going at its deadline: SIGKILL to
  every process group in its tree.

  What the runner prints is logged (it's the listener's status, never job
  output) and watched for two states: `Listening for Jobs` is
  `runner_listening`, and `Running job:` (the listener handing the job to a
  worker) is `job_started`. When the runner exits, and everything holding
  its output has closed it, `:on_exit` gets its exit status (128 + n for
  signal n).
  """

  use GenServer, restart: :temporary

  require Logger

  @max_logged 1_024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Sends the runner SIGTERM, the first time it's called."
  def stop(server), do: GenServer.call(server, :stop)

  @doc """
  SIGKILLs the runner and everything it started: each process group in its
  tree, and each process, from one `ps` snapshot. crew-guest's own group
  is never one of them.
  """
  def kill(server), do: GenServer.call(server, :kill)

  @doc false
  # From `ps -A -o pid=,ppid=,pgid=`: the process groups in `root`'s tree
  # but `own_pgid`, and the processes in it, `root` included.
  def kill_targets(ps, root, own_pgid) do
    procs = for line <- String.split(ps, "\n"), {:ok, proc} <- [parse_proc(line)], do: proc
    children = Enum.group_by(procs, fn {_pid, ppid, _pgid} -> ppid end)
    pids = tree(children, [root], [])

    groups =
      for {pid, _ppid, pgid} <- procs,
          pid in pids,
          pgid > 1 and pgid != own_pgid,
          uniq: true,
          do: pgid

    {Enum.sort(groups), Enum.sort(pids)}
  end

  defp tree(_children, [], acc), do: acc

  defp tree(children, [pid | rest], acc) do
    kids = for {kid, _ppid, _pgid} <- Map.get(children, pid, []), kid not in acc, do: kid
    tree(children, kids ++ rest, [pid | acc])
  end

  defp parse_proc(line) do
    case line |> String.split() |> Enum.map(&Integer.parse/1) do
      [{pid, ""}, {ppid, ""}, {pgid, ""}] -> {:ok, {pid, ppid, pgid}}
      _ -> :error
    end
  end

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
       signalled: false,
       on_state: Keyword.fetch!(opts, :on_state),
       on_exit: Keyword.fetch!(opts, :on_exit)
     }}
  end

  @impl true
  def handle_call(:stop, _from, %{signalled: true} = s), do: {:reply, :ok, s}

  def handle_call(:stop, _from, s) do
    Logger.info("crew-guest: sending the runner SIGTERM")
    System.cmd("kill", ["-TERM", Integer.to_string(s.os_pid)], stderr_to_stdout: true)
    {:reply, :ok, %{s | signalled: true}}
  end

  def handle_call(:kill, _from, s) do
    Logger.warning("crew-guest: killing the runner and everything it started")

    {groups, pids} =
      case System.cmd("ps", ["-A", "-o", "pid=,ppid=,pgid="], stderr_to_stdout: true) do
        {ps, 0} -> kill_targets(ps, s.os_pid, own_pgid(ps))
        # The Port's process leads its own group.
        _failed -> {[s.os_pid], [s.os_pid]}
      end

    targets = Enum.map(groups, &"-#{&1}") ++ Enum.map(pids, &Integer.to_string/1)
    System.cmd("kill", ["-KILL", "--" | targets], stderr_to_stdout: true)
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

  defp own_pgid(ps) do
    own = String.to_integer(System.pid())

    Enum.find_value(String.split(ps, "\n"), fn line ->
      case parse_proc(line) do
        {:ok, {^own, _ppid, pgid}} -> pgid
        _other -> nil
      end
    end)
  end
end
