defmodule CrewCache.FakeDNS do
  @moduledoc """
  An upstream resolver for tests, on 127.0.0.1 (UDP and TCP, one port).
  It answers from a map of `{name, type}` to `[{ttl, data}]`, marks
  answers truncated over UDP for names in `truncate`, and records each
  query's id, source port and transport.
  """
  use GenServer

  def start(zones, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {zones, opts})
    %{pid: pid, port: GenServer.call(pid, :port)}
  end

  def queries(fake), do: GenServer.call(fake.pid, :queries)

  @impl true
  def init({zones, opts}) do
    {:ok, udp} = :gen_udp.open(0, [:binary, ip: {127, 0, 0, 1}, active: true])
    {:ok, port} = :inet.port(udp)

    {:ok, listen} =
      :gen_tcp.listen(port, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: 2,
        active: false,
        reuseaddr: true
      ])

    me = self()
    spawn_link(fn -> accept(listen, me) end)

    {:ok,
     %{
       udp: udp,
       port: port,
       zones: zones,
       truncate: Keyword.get(opts, :truncate, []),
       queries: []
     }}
  end

  defp accept(listen, me) do
    {:ok, socket} = :gen_tcp.accept(listen)

    with {:ok, packet} <- :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {_, port}} = :inet.peername(socket)
      reply = GenServer.call(me, {:answer, packet, port, :tcp})
      :gen_tcp.send(socket, reply)
    end

    :gen_tcp.close(socket)
    accept(listen, me)
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:queries, _from, state), do: {:reply, Enum.reverse(state.queries), state}

  def handle_call({:answer, packet, port, transport}, _from, state) do
    {reply, state} = answer(packet, port, transport, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, state) do
    {reply, state} = answer(packet, port, :udp, state)
    :gen_udp.send(socket, ip, port, reply)
    {:noreply, state}
  end

  defp answer(packet, port, transport, state) do
    {:ok, msg} = :inet_dns.decode(packet)
    header = :inet_dns.msg(msg, :header)
    [question] = :inet_dns.msg(msg, :qdlist)
    name = question |> :inet_dns.dns_query(:domain) |> to_string() |> String.downcase()
    type = :inet_dns.dns_query(question, :type)
    id = :inet_dns.header(header, :id)

    state = %{
      state
      | queries: [
          %{id: id, port: port, transport: transport, name: name, type: type} | state.queries
        ]
    }

    records = Map.get(state.zones, {name, type})
    truncate? = transport == :udp and name in state.truncate

    answers =
      if truncate?,
        do: [],
        else:
          for(
            {ttl, data} <- records || [],
            do:
              :inet_dns.make_rr(domain: ~c"#{name}", type: type, class: :in, ttl: ttl, data: data)
          )

    reply =
      :inet_dns.make_msg(
        header:
          :inet_dns.make_header(
            id: id,
            qr: true,
            opcode: :query,
            rd: true,
            ra: true,
            tc: truncate?,
            rcode: if(records == nil and not truncate?, do: 3, else: 0)
          ),
        qdlist: [question],
        anlist: answers
      )

    {:inet_dns.encode(reply), state}
  end
end
