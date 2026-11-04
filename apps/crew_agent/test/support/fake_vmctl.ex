defmodule CrewAgent.FakeVmctl do
  @moduledoc """
  A stand-in for crew-vmctl's socket (`native/crew-vmctl/README.md`): one
  JSON request per connection, one line back. Each request is sent to
  the test process as `{:vmctl, request}`, and answered by
  `answer.(request)` (a map, encoded as one line).
  """
  use GenServer

  def start_link({path, answer, test}), do: GenServer.start_link(__MODULE__, {path, answer, test})

  @doc "Every request so far, oldest first, without waiting."
  def requests do
    Stream.repeatedly(fn ->
      receive do
        {:vmctl, req} -> req
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

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

    spawn_link(fn -> accept(listen, answer, test) end)
    {:ok, %{listen: listen, path: path}}
  end

  defp accept(listen, answer, test) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        spawn(fn -> serve(conn, answer, test) end)
        accept(listen, answer, test)

      {:error, _} ->
        :ok
    end
  end

  # One request, one answer, then the connection is closed (crew-vmctl
  # serve exits).
  defp serve(conn, answer, test) do
    with {:ok, line} <- :gen_tcp.recv(conn, 0, 5_000) do
      req = Jason.decode!(line)
      send(test, {:vmctl, req})
      :gen_tcp.send(conn, [Jason.encode!(answer.(req)), ?\n])
    end

    :gen_tcp.close(conn)
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end
end
