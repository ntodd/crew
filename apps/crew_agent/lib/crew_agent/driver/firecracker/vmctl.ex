defmodule CrewAgent.Driver.Firecracker.Vmctl do
  @moduledoc """
  A client for crew-vmctl's socket (§10.8, `native/crew-vmctl/README.md`):
  one JSON request per connection, one line back. systemd starts a
  crew-vmctl for each connection, so calls don't queue behind each other.

  Answers are `{:ok, map}` or `{:error, code, detail}` with crew-vmctl's
  error codes; a socket that can't be reached is
  `{:error, "unreachable", reason}`.
  """

  @connect_ms 2_000
  @max_line 64 * 1024

  # `start` lays out the jail and waits for systemd-run; `cleanup` may
  # wait for a SIGKILLed unit; `nft-verify` loads a reference ruleset.
  @timeouts %{"start" => 60_000, "cleanup" => 30_000, "nft-verify" => 30_000, "reboot" => 30_000}

  @spec request(String.t(), map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def request(socket, %{"verb" => verb} = req) do
    timeout = Map.get(@timeouts, verb, 10_000)

    with {:ok, conn} <- connect(socket) do
      try do
        with :ok <- send_line(conn, req),
             {:ok, line} <- read_line(conn, timeout) do
          decode(line)
        end
      after
        :gen_tcp.close(conn)
      end
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

  defp send_line(conn, req) do
    case :gen_tcp.send(conn, [Jason.encode!(req), ?\n]) do
      :ok -> :ok
      {:error, reason} -> {:error, "unreachable", inspect(reason)}
    end
  end

  defp read_line(conn, timeout) do
    case :gen_tcp.recv(conn, 0, timeout) do
      {:ok, line} when byte_size(line) <= @max_line -> {:ok, line}
      {:ok, _} -> {:error, "bad_response", "line too long"}
      {:error, reason} -> {:error, "unreachable", inspect(reason)}
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
