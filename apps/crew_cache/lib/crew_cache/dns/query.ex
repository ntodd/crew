defmodule CrewCache.DNS.Query do
  @moduledoc """
  One query, start to answer, with `:inet_dns`:

  - not DNS, or a response rather than a query: dropped;
  - over the client's rate: REFUSED;
  - not a standard query: NOTIMP; not exactly one question: FORMERR;
  - refused by `CrewCache.DNS.Policy`: REFUSED;
  - otherwise from the cache, or the upstreams (stripped, then cached
    when it's NOERROR or NXDOMAIN); no upstream answering: SERVFAIL.

  Over UDP an answer is cut to the client's EDNS size (512 bytes
  without EDNS, at most 1232) and marked truncated, so it retries over
  TCP.
  """

  alias CrewCache.{Config, Net}
  alias CrewCache.DNS.{Cache, Forward, Policy}

  @noerror 0
  @formerr 1
  @servfail 2
  @nxdomain 3
  @notimp 4
  @refused 5

  @doc "`{:reply, binary}` or `:drop`."
  def handle(packet, _client_ip, transport, limited?) do
    with {:ok, msg} <- :inet_dns.decode(packet),
         header = :inet_dns.msg(msg, :header),
         false <- :inet_dns.header(header, :qr) do
      {:reply, encode(answer(msg, header, limited?), msg, transport)}
    else
      _ -> :drop
    end
  end

  defp answer(msg, header, limited?) do
    questions = :inet_dns.msg(msg, :qdlist)

    cond do
      limited? -> reply(questions, @refused)
      :inet_dns.header(header, :opcode) != :query -> reply(questions, @notimp)
      length(questions) != 1 -> reply(questions, @formerr)
      true -> resolve(hd(questions))
    end
  end

  defp reply(questions, rcode, an \\ [], ns \\ [], ar \\ []),
    do: %{questions: questions, rcode: rcode, an: an, ns: ns, ar: ar}

  defp resolve(question) do
    name =
      question
      |> :inet_dns.dns_query(:domain)
      |> to_string()
      |> String.downcase()
      |> String.trim_trailing(".")

    type = :inet_dns.dns_query(question, :type)
    policy = Net.current()

    if Policy.refuse?(name, type, policy) do
      reply([question], @refused)
    else
      key = {name, type, :inet_dns.dns_query(question, :class)}

      case Cache.get(key) do
        {:ok, cached} -> %{cached | questions: [question]}
        :miss -> forward(question, key, policy)
      end
    end
  end

  defp forward(question, key, policy) do
    case Forward.query(question, Config.get().dns_upstreams) do
      {:ok, msg} ->
        rcode = msg |> :inet_dns.msg(:header) |> :inet_dns.header(:rcode)
        an = msg |> :inet_dns.msg(:anlist) |> Policy.strip(policy) |> cap()
        ns = msg |> :inet_dns.msg(:nslist) |> Policy.strip(policy) |> cap()

        ar =
          msg |> :inet_dns.msg(:arlist) |> Enum.reject(&opt?/1) |> Policy.strip(policy) |> cap()

        result = reply([question], rcode, an, ns, ar)
        if rcode in [@noerror, @nxdomain], do: Cache.put(key, result, ttl(an ++ ns))
        result

      {:error, _} ->
        reply([question], @servfail)
    end
  end

  defp opt?(rr), do: elem(rr, 0) == :dns_rr_opt

  # TTLs at most 300 s, in the answer as in the cache.
  defp cap(rrs) do
    Enum.map(rrs, &:inet_dns.make_rr(&1, ttl: min(:inet_dns.rr(&1, :ttl), Cache.max_ttl())))
  end

  defp ttl([]), do: 0

  defp ttl(rrs),
    do: rrs |> Enum.map(&:inet_dns.rr(&1, :ttl)) |> Enum.min() |> min(Cache.max_ttl())

  # -- the answer on the wire ----------------------------------------------------------

  defp encode(result, query, transport) do
    query_header = :inet_dns.msg(query, :header)
    client_opt = query |> :inet_dns.msg(:arlist) |> Enum.find(&opt?/1)
    opt = if client_opt, do: [:inet_dns.make_rr(type: :opt, udp_payload_size: 1232)], else: []

    header = fn tc ->
      :inet_dns.make_header(
        id: :inet_dns.header(query_header, :id),
        qr: true,
        opcode: :inet_dns.header(query_header, :opcode),
        rd: :inet_dns.header(query_header, :rd),
        ra: true,
        tc: tc,
        rcode: result.rcode
      )
    end

    full =
      :inet_dns.encode(
        :inet_dns.make_msg(
          header: header.(false),
          qdlist: result.questions,
          anlist: result.an,
          nslist: result.ns,
          arlist: result.ar ++ opt
        )
      )

    if transport == :udp and byte_size(full) > udp_limit(client_opt) do
      :inet_dns.encode(
        :inet_dns.make_msg(header: header.(true), qdlist: result.questions, arlist: opt)
      )
    else
      full
    end
  end

  defp udp_limit(nil), do: 512
  defp udp_limit(opt), do: opt |> elem(3) |> max(512) |> min(1232)
end
