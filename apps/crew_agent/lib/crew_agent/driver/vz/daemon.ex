defmodule CrewAgent.Driver.VZ.Daemon do
  @moduledoc """
  A client for crew-vzd's control socket (§11.4,
  `native/crew-vz/README.md`): JSON lines over a Unix socket, one
  response per request. Each call opens its own connection, so a slow
  `start` doesn't hold up a `status`, and a daemon restart costs nothing
  but the calls in flight.

  Answers are `{:ok, map}` or `{:error, code, detail}` with crew-vzd's
  error codes; a daemon that can't be reached is
  `{:error, "unreachable", reason}`.
  """

  @connect_ms 2_000
  @max_line 64 * 1024

  # `start` returns once the VM runs (about 130 ms); a forced `stop` once
  # the helper has gone, which crew-vzd bounds at 5 s.
  @timeouts %{"start" => 30_000, "stop" => 15_000}

  @spec request(String.t(), map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def request(socket, %{"op" => op} = req) do
    timeout = Map.get(@timeouts, op, 5_000)

    with {:ok, conn} <- connect(socket),
         :ok <- :gen_tcp.send(conn, [Jason.encode!(req), ?\n]) |> sent(conn),
         {:ok, line} <- read_line(conn, timeout) do
      :gen_tcp.close(conn)
      decode(line)
    end
  end

  defp connect(socket) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(socket)},
           0,
           [:binary, active: false, packet: :line, buffer: @max_line + 1],
           @connect_ms
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "unreachable", inspect(reason)}
    end
  end

  defp sent(:ok, _conn), do: :ok

  defp sent({:error, reason}, conn) do
    :gen_tcp.close(conn)
    {:error, "unreachable", inspect(reason)}
  end

  defp read_line(conn, timeout) do
    case :gen_tcp.recv(conn, 0, timeout) do
      {:ok, line} when byte_size(line) <= @max_line ->
        {:ok, line}

      {:ok, _} ->
        :gen_tcp.close(conn)
        {:error, "bad_response", "line too long"}

      {:error, reason} ->
        :gen_tcp.close(conn)
        {:error, "unreachable", inspect(reason)}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{"ok" => true} = resp} -> {:ok, resp}
      {:ok, %{"ok" => false, "error" => code} = resp} -> {:error, code, resp["detail"] || ""}
      _ -> {:error, "bad_response", String.slice(line, 0, 200)}
    end
  end
end
