defmodule CrewCache.DNS.Forward do
  @moduledoc """
  Asking the upstreams (`CREW_DNS_UPSTREAMS`, in order): each query
  gets a random id and goes out from a fresh socket on a random port.
  An answer only counts if it comes from the server asked, with that id
  and the same question; anything else is ignored. A truncated answer
  is asked again over TCP.
  """

  @timeout_ms 2_000

  @doc "`{:ok, message}` from the first upstream that answers, or `{:error, reason}`."
  def query(question, upstreams, timeout \\ @timeout_ms) do
    Enum.reduce_while(upstreams, {:error, :no_upstreams}, fn {ip, port}, _ ->
      case ask(question, ip, port, timeout) do
        {:ok, msg} -> {:halt, {:ok, msg}}
        error -> {:cont, error}
      end
    end)
  end

  defp ask(question, ip, port, timeout) do
    case udp(question, ip, port, timeout) do
      {:ok, msg} ->
        if msg |> :inet_dns.msg(:header) |> :inet_dns.header(:tc),
          do: tcp(question, ip, port, timeout),
          else: {:ok, msg}

      error ->
        error
    end
  end

  defp encode(question, id) do
    :inet_dns.encode(
      :inet_dns.make_msg(
        header: :inet_dns.make_header(id: id, rd: true, opcode: :query),
        qdlist: [question],
        arlist: [:inet_dns.make_rr(type: :opt, udp_payload_size: 1232)]
      )
    )
  end

  defp new_id do
    <<id::16>> = :crypto.strong_rand_bytes(2)
    id
  end

  defp udp(question, ip, port, timeout) do
    id = new_id()

    with {:ok, socket} <- open_random() do
      try do
        :ok = :gen_udp.send(socket, ip, port, encode(question, id))
        receive_answer(socket, ip, port, id, question, deadline(timeout))
      after
        :gen_udp.close(socket)
      end
    end
  end

  # A random port from 1024 up; the OS's choice if those few tries are taken.
  defp open_random(tries \\ 5)
  defp open_random(0), do: :gen_udp.open(0, [:binary, active: false])

  defp open_random(tries) do
    <<n::16>> = :crypto.strong_rand_bytes(2)

    case :gen_udp.open(1024 + rem(n, 64_512), [:binary, active: false]) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} -> open_random(tries - 1)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp receive_answer(socket, ip, port, id, question, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    with true <- left > 0 || {:error, :timeout},
         {:ok, {^ip, ^port, packet}} <- :gen_udp.recv(socket, 0, left),
         {:ok, msg} <- answer_to(packet, id, question) do
      {:ok, msg}
    else
      {:error, :timeout} = error -> error
      {:error, reason} when reason != :mismatch -> {:error, reason}
      _ -> receive_answer(socket, ip, port, id, question, deadline)
    end
  end

  defp tcp(question, ip, port, timeout) do
    id = new_id()

    with {:ok, socket} <- :gen_tcp.connect(ip, port, [:binary, packet: 2, active: false], timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, encode(question, id)),
             {:ok, packet} <- :gen_tcp.recv(socket, 0, timeout) do
          answer_to(packet, id, question)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp answer_to(packet, id, question) do
    with {:ok, msg} <- :inet_dns.decode(packet),
         header = :inet_dns.msg(msg, :header),
         true <- :inet_dns.header(header, :qr),
         ^id <- :inet_dns.header(header, :id),
         [answered] <- :inet_dns.msg(msg, :qdlist),
         true <- same?(answered, question) do
      {:ok, msg}
    else
      _ -> {:error, :mismatch}
    end
  end

  defp same?(a, b) do
    norm = fn q ->
      {q |> :inet_dns.dns_query(:domain) |> to_string() |> String.downcase(),
       :inet_dns.dns_query(q, :type), :inet_dns.dns_query(q, :class)}
    end

    norm.(a) == norm.(b)
  end
end
