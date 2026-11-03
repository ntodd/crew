defmodule CrewAgent.FakeVzd do
  @moduledoc """
  A stand-in for crew-vzd's control socket: JSON lines on a Unix socket.
  Each request is sent to the test process as `{:vzd, request}`, and
  answered by `answer.(request)` (a map, encoded as one line).
  """
  use GenServer

  def start_link({path, answer, test}), do: GenServer.start_link(__MODULE__, {path, answer, test})

  @impl true
  def init({path, answer, test}) do
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        ifaddr: {:local, String.to_charlist(path)}
      ])

    me = self()
    spawn_link(fn -> accept(listen, answer, test, me) end)
    {:ok, %{listen: listen, path: path}}
  end

  defp accept(listen, answer, test, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        spawn(fn -> serve(conn, answer, test) end)
        accept(listen, answer, test, owner)

      {:error, _} ->
        :ok
    end
  end

  defp serve(conn, answer, test) do
    case :gen_tcp.recv(conn, 0, 5_000) do
      {:ok, line} ->
        req = Jason.decode!(line)
        send(test, {:vzd, req})
        :gen_tcp.send(conn, [Jason.encode!(answer.(req)), ?\n])
        serve(conn, answer, test)

      {:error, _} ->
        :gen_tcp.close(conn)
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end
end
