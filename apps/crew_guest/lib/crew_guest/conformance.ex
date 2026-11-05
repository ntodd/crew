defmodule CrewGuest.Conformance do
  @moduledoc """
  Conformance mode (§11.6): with a `conformance` object in its payload,
  crew-guest runs the guest image's fixed check script instead of the
  runner, and reports what it prints as log lines.

  **Only the agent turns it on:** it adds the object only when its own
  config has `CREW_CONFORMANCE=1` (`CrewAgent.Conformance`).

  **Nothing in the payload runs.** The script is `Config.conformance_cmd`
  (`/opt/crew/conformance/check`, baked into the signed image), which
  nothing in the payload, the environment or the command line can
  change. The object is checked with `CrewProtocol.Guest.cast_conformance/1`
  (checks from a fixed list, bounded values); one that doesn't pass is
  refused and the VM powers off. What passes is written, with the VM's
  size, to `<run_dir>/conformance.json`, and the script is given that
  path and nothing else. It runs as root (the job would have root too),
  with a clean environment.
  """

  alias CrewProtocol.Guest

  @file_name "conformance.json"

  @doc """
  The payload's conformance object: `nil` when there's none (run the
  job), `{:ok, object}`, or `{:error, reasons}` when it doesn't validate.
  """
  @spec parse(map()) :: nil | {:ok, map()} | {:error, [String.t()]}
  def parse(%{"conformance" => nil}), do: nil
  def parse(%{"conformance" => c}), do: Guest.cast_conformance(c)
  def parse(_payload), do: nil

  @doc "The run dir's files for the check: the object, and the VM's size to check against."
  def files(object, payload) do
    body = Map.put(object, "size", Map.get(payload, "size") || %{})
    [{@file_name, Jason.encode!(body), :public}]
  end

  def file_name, do: @file_name
end

defmodule CrewGuest.Conformance.Check do
  @moduledoc """
  Runs the conformance script through a Port, like `CrewGuest.Runner`
  runs the runner, and with the same `stop/1` (one SIGTERM) and `kill/1`
  (SIGKILL to everything it started). Each line it prints goes to
  `:on_line`; its exit status to `:on_exit`.
  """

  use GenServer, restart: :temporary

  require Logger

  @max_line 4_096
  @path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def stop(server), do: GenServer.call(server, :stop)
  def kill(server), do: GenServer.call(server, :kill)

  @impl true
  def init(opts) do
    cfg = Keyword.fetch!(opts, :config)
    file = Keyword.fetch!(opts, :file)

    # A clean environment: none of the release's variables, and nothing
    # to reach systemd as crew-guest with. `runner_env` is the tests'.
    env =
      ["PATH=#{@path}", "HOME=/root", "LANG=C.UTF-8"] ++
        for({k, v} <- cfg.runner_env, do: "#{k}=#{v}")

    port =
      Port.open({:spawn_executable, "/usr/bin/env"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 16_384},
        {:args, ["-i" | env] ++ [cfg.conformance_cmd, file]},
        {:cd, "/"}
      ])

    os_pid = CrewGuest.Runner.os_pid(port)
    Logger.info("crew-guest: started the conformance check (pid #{os_pid || "gone"})")

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       buf: "",
       signalled: false,
       on_line: Keyword.fetch!(opts, :on_line),
       on_exit: Keyword.fetch!(opts, :on_exit)
     }}
  end

  # It exited before init could ask for its pid: nothing to signal.
  @impl true
  def handle_call(_stop_or_kill, _from, %{os_pid: nil} = s), do: {:reply, :ok, s}

  def handle_call(:stop, _from, %{signalled: true} = s), do: {:reply, :ok, s}

  def handle_call(:stop, _from, s) do
    System.cmd("kill", ["-TERM", Integer.to_string(s.os_pid)], stderr_to_stdout: true)
    {:reply, :ok, %{s | signalled: true}}
  end

  def handle_call(:kill, _from, s) do
    own = String.to_integer(System.pid())

    {groups, pids} =
      case System.cmd("ps", ["-A", "-o", "pid=,ppid=,pgid="], stderr_to_stdout: true) do
        {ps, 0} -> CrewGuest.Runner.kill_targets(ps, s.os_pid, own_pgid(ps, own))
        _failed -> {[], [s.os_pid]}
      end

    targets = Enum.map(groups, &"-#{&1}") ++ Enum.map(pids, &Integer.to_string/1)
    System.cmd("kill", ["-KILL", "--" | targets], stderr_to_stdout: true)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = s) do
    buf = if byte_size(s.buf) < @max_line, do: s.buf <> part, else: s.buf
    {:noreply, %{s | buf: buf}}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = s) do
    s.on_line.(binary_part_safe(s.buf <> part))
    {:noreply, %{s | buf: ""}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
    Logger.info("crew-guest: the conformance check exited with status #{status}")
    if s.buf != "", do: s.on_line.(binary_part_safe(s.buf))
    s.on_exit.(status)
    {:stop, :normal, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp binary_part_safe(line), do: String.slice(line, 0, @max_line)

  defp own_pgid(ps, own) do
    Enum.find_value(String.split(ps, "\n"), fn line ->
      case line |> String.split() |> Enum.map(&Integer.parse/1) do
        [{^own, ""}, {_ppid, ""}, {pgid, ""}] -> pgid
        _other -> nil
      end
    end)
  end
end
