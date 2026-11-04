defmodule CrewImage.Smoke.VZD do
  @moduledoc """
  Runs `crew-vz daemon` and speaks its protocol (native/crew-vz/README.md):
  JSON lines over a Unix socket, one response per request.
  """

  @doc "Starts the daemon on `<data>/vzd.sock`, logging to `<data>/vzd.log`; waits until it answers."
  def start(bin, data) do
    sock = Path.join(data, "vzd.sock")
    log = Path.join(data, "vzd.log")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: [
          "-c",
          ~s(exec "$0" daemon --socket "$1" --data-dir "$2" -v >>"$3" 2>&1),
          bin,
          sock,
          data,
          log
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + 10_000

    case wait_ready(sock, deadline) do
      :ok -> {:ok, %{sock: sock, pid: pid, port: port, log: log}}
      :timeout -> {:error, {:daemon_not_ready, File.read(log)}}
    end
  end

  def stop(%{pid: pid}) do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  @doc "One request, one response."
  def call(sock, request, timeout \\ 60_000) do
    with {:ok, c} <-
           :gen_tcp.connect(
             {:local, sock},
             0,
             [:binary, packet: :line, active: false, buffer: 131_072],
             5_000
           ) do
      try do
        :ok = :gen_tcp.send(c, [Jason.encode!(request), "\n"])

        case :gen_tcp.recv(c, 0, timeout) do
          {:ok, line} -> Jason.decode(line)
          error -> error
        end
      after
        :gen_tcp.close(c)
      end
    end
  end

  def status(sock, vm_id), do: call(sock, %{op: "status", vm_id: vm_id})

  defp wait_ready(sock, deadline) do
    case call(sock, %{op: "list"}, 2_000) do
      {:ok, %{"ok" => true}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          wait_ready(sock, deadline)
        else
          :timeout
        end
    end
  end
end
