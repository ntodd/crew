defmodule CrewCache.DNS.Server do
  @moduledoc """
  The resolver's sockets: UDP, and TCP on the same port. Each UDP query
  is answered in its own task (at most 2048 at once; past that they're
  dropped, as a full resolver would); each TCP connection gets a task
  that answers up to 100 queries, 10 s apart at most.

  The per-client rate limit is checked here, as each query arrives.
  """
  use GenServer

  require Logger

  alias CrewCache.DNS.{Cache, Query}

  @tasks CrewCache.DNS.Tasks
  @tcp_idle_ms 10_000
  @tcp_max_queries 100
  @max_tcp 256

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    {:ok, udp} =
      :gen_udp.open(config.dns_port, [:binary, ip: config.listen, active: 100, recbuf: 1_048_576])

    {:ok, port} = :inet.port(udp)

    {:ok, listen} =
      :gen_tcp.listen(port, [
        :binary,
        ip: config.listen,
        packet: 2,
        active: false,
        reuseaddr: true,
        backlog: 128
      ])

    :persistent_term.put({CrewCache.DNS, :port}, port)
    acceptor = spawn_link(fn -> accept(listen) end)
    {:ok, %{udp: udp, listen: listen, acceptor: acceptor}}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, state) do
    limited? = not Cache.allow?(ip)

    Task.Supervisor.start_child(@tasks, fn ->
      case Query.handle(packet, ip, :udp, limited?) do
        {:reply, reply} -> :gen_udp.send(socket, ip, port, reply)
        :drop -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info({:udp_passive, socket}, state) do
    :inet.setopts(socket, active: 100)
    {:noreply, state}
  end

  defp accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        start_session(socket)
        accept(listen)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("DNS TCP accept: #{inspect(reason)}")
        Process.sleep(100)
        accept(listen)
    end
  end

  defp start_session(socket) do
    with true <- Task.Supervisor.children(@tasks) |> length() < @max_tcp,
         {:ok, pid} <- Task.Supervisor.start_child(@tasks, fn -> session(socket) end),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      send(pid, :go)
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  defp session(socket) do
    receive do
      :go -> :ok
    after
      5_000 -> exit(:normal)
    end

    case :inet.peername(socket) do
      {:ok, {ip, _}} -> serve(socket, ip, @tcp_max_queries)
      _ -> :ok
    end

    :gen_tcp.close(socket)
  end

  defp serve(_socket, _ip, 0), do: :ok

  defp serve(socket, ip, left) do
    with {:ok, packet} <- :gen_tcp.recv(socket, 0, @tcp_idle_ms),
         {:reply, reply} <- Query.handle(packet, ip, :tcp, not Cache.allow?(ip)),
         :ok <- :gen_tcp.send(socket, reply) do
      serve(socket, ip, left - 1)
    end
  end
end
