defmodule CrewCache.DNSTest do
  use ExUnit.Case, async: false

  alias CrewCache.FakeDNS

  @moduletag :tmp_dir

  @zones %{
    {"example.com", :a} => [{3600, {93, 184, 216, 34}}],
    {"mixed.example", :a} => [{60, {10, 0, 0, 5}}, {60, {1, 2, 3, 4}}, {60, {169, 254, 169, 254}}],
    {"loop.example", :a} => [{60, {127, 0, 0, 1}}],
    {"site.example", :a} => [{60, {81, 2, 3, 4}}],
    {"six.example", :aaaa} => [
      {60, {0, 0, 0, 0, 0, 0, 0, 1}},
      {60, {0xFD00, 0, 0, 0, 0, 0, 0, 1}},
      {60, {0xFE80, 0, 0, 0, 0, 0, 0, 1}},
      {60, {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}},
      {60, {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}}
    ],
    {"big.example", :a} => for(n <- 1..40, do: {60, {1, 1, 1, n}}),
    {"8.8.8.8.in-addr.arpa", :ptr} => [{60, ~c"dns.google"}],
    {"short.example", :a} => [{1, {5, 6, 7, 8}}]
  }

  setup %{tmp_dir: dir} = tags do
    fake = FakeDNS.start(@zones, truncate: ["big.example"])

    start_supervised!(
      {CrewCache,
       [
         dir: dir,
         listen: {127, 0, 0, 1},
         registry: false,
         mgmt: nil,
         dns_port: 0,
         dns_upstreams: [{{127, 0, 0, 1}, fake.port}],
         site4: ["81.2.3.0/24"],
         max_bytes: 1_000_000
       ] ++ Map.get(tags, :cache, [])}
    )

    %{fake: fake, port: CrewCache.ports().dns}
  end

  defp resolve(port, name, type, opts \\ []) do
    :inet_res.resolve(
      String.to_charlist(name),
      :in,
      type,
      opts ++ [nameservers: [{{127, 0, 0, 1}, port}], retry: 1, timeout: 2000]
    )
  end

  defp answers({:ok, msg}),
    do: for(rr <- :inet_dns.msg(msg, :anlist), do: :inet_dns.rr(rr, :data))

  defp rcode({:ok, msg}), do: msg |> :inet_dns.msg(:header) |> :inet_dns.header(:rcode)
  defp rcode({:error, {reason, _msg}}), do: reason
  defp rcode({:error, reason}), do: reason

  test "resolves through CREW_DNS_UPSTREAMS", %{port: port} do
    assert answers(resolve(port, "example.com", :a)) == [{93, 184, 216, 34}]
    assert rcode(resolve(port, "nowhere.example", :a)) == :nxdomain
  end

  test "strips answers in blocked4 and site4", %{port: port} do
    assert answers(resolve(port, "mixed.example", :a)) == [{1, 2, 3, 4}]
    assert answers(resolve(port, "loop.example", :a)) == []
    assert answers(resolve(port, "site.example", :a)) == []
  end

  test "strips AAAA answers that are loopback, link-local, ULA or mapped blocked4", %{port: port} do
    assert answers(resolve(port, "six.example", :aaaa)) == [
             {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}
           ]
  end

  describe "refuses" do
    test "ANY and zone transfers", %{port: port, fake: fake} do
      assert rcode(resolve(port, "example.com", :any)) == :refused
      assert rcode(resolve(port, "example.com", :axfr, usevc: true)) == :refused
      assert rcode(resolve(port, "example.com", :ixfr)) == :refused
      assert FakeDNS.queries(fake) == []
    end

    test "private suffixes", %{port: port, fake: fake} do
      for name <- ~w(printer.local router.lan svc.internal nas.home.arpa box.tail1234.ts.net
                     app.localhost localhost lan LOCAL) do
        assert rcode(resolve(port, name, :a)) == :refused, name
      end

      assert FakeDNS.queries(fake) == []
    end

    test "reverse lookups in private ranges, but not public ones", %{port: port, fake: fake} do
      for name <- ~w(1.0.168.192.in-addr.arpa 5.0.0.10.in-addr.arpa 10.in-addr.arpa
                     1.0.0.127.in-addr.arpa 254.169.254.169.in-addr.arpa 168.192.in-addr.arpa
                     1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa) do
        assert rcode(resolve(port, name, :ptr)) == :refused, name
      end

      assert FakeDNS.queries(fake) == []
      assert answers(resolve(port, "8.8.8.8.in-addr.arpa", :ptr)) == [~c"dns.google"]
    end
  end

  describe "the cache" do
    test "answers again without asking, with TTLs capped at 300 s", %{port: port, fake: fake} do
      {:ok, first} = resolve(port, "example.com", :a)
      {:ok, second} = resolve(port, "example.com", :a)
      assert length(FakeDNS.queries(fake)) == 1

      for msg <- [first, second], rr <- :inet_dns.msg(msg, :anlist) do
        assert :inet_dns.rr(rr, :ttl) <= 300
      end
    end

    test "entries expire with their TTL", %{port: port, fake: fake} do
      resolve(port, "short.example", :a)
      Process.sleep(1100)
      resolve(port, "short.example", :a)
      assert length(FakeDNS.queries(fake)) == 2
    end
  end

  test "upstream queries get fresh ids and source ports", %{port: port, fake: fake} do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    for n <- 1..10 do
      query =
        :inet_dns.encode(
          :inet_dns.make_msg(
            header: :inet_dns.make_header(id: 4242, rd: true, opcode: :query),
            qdlist: [:inet_dns.make_dns_query(domain: ~c"n#{n}.example", type: :a, class: :in)]
          )
        )

      :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, query)
      {:ok, {_, _, reply}} = :gen_udp.recv(socket, 0, 2000)
      {:ok, msg} = :inet_dns.decode(reply)
      assert msg |> :inet_dns.msg(:header) |> :inet_dns.header(:id) == 4242
    end

    queries = FakeDNS.queries(fake)
    assert length(queries) == 10
    refute Enum.any?(queries, &(&1.id == 4242))
    assert queries |> Enum.map(& &1.port) |> Enum.uniq() |> length() >= 8
    assert queries |> Enum.map(& &1.id) |> Enum.uniq() |> length() >= 8
  end

  test "an upstream answer truncated over UDP is fetched again over TCP", %{
    port: port,
    fake: fake
  } do
    {:ok, msg} = resolve(port, "big.example", :a, usevc: true)
    assert length(answers({:ok, msg})) == 40
    assert Enum.any?(FakeDNS.queries(fake), &(&1.transport == :tcp))
  end

  test "an answer too big for the client's UDP size is truncated for it", %{port: port} do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    query =
      :inet_dns.encode(
        :inet_dns.make_msg(
          header: :inet_dns.make_header(id: 7, rd: true, opcode: :query),
          qdlist: [:inet_dns.make_dns_query(domain: ~c"big.example", type: :a, class: :in)]
        )
      )

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, query)
    {:ok, {_, _, reply}} = :gen_udp.recv(socket, 0, 2000)
    assert byte_size(reply) <= 512
    {:ok, msg} = :inet_dns.decode(reply)
    assert msg |> :inet_dns.msg(:header) |> :inet_dns.header(:tc)
  end

  # Over the limit, UDP queries are dropped without a reply (and without
  # costing a task); TCP ones are answered REFUSED.
  test "limits each client to 100 queries a second", %{port: port} do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    query = fn id ->
      :inet_dns.encode(
        :inet_dns.make_msg(
          header: :inet_dns.make_header(id: id, rd: true, opcode: :query),
          qdlist: [:inet_dns.make_dns_query(domain: ~c"example.com", type: :a, class: :in)]
        )
      )
    end

    for id <- 1..150, do: :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, query.(id))

    rcodes = replies(socket, [])
    assert length(rcodes) >= 90
    assert length(rcodes) <= 115
    assert Enum.all?(rcodes, &(&1 == 0))
  end

  defp replies(socket, acc) do
    case :gen_udp.recv(socket, 0, 500) do
      {:ok, {_, _, reply}} ->
        {:ok, msg} = :inet_dns.decode(reply)
        replies(socket, [msg |> :inet_dns.msg(:header) |> :inet_dns.header(:rcode) | acc])

      {:error, :timeout} ->
        acc
    end
  end

  test "caps each client's TCP connections", %{port: port} do
    sockets =
      for _ <- 1..20 do
        {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 2, active: false])
        s
      end

    closed = Enum.count(sockets, &(:gen_tcp.recv(&1, 0, 300) == {:error, :closed}))
    assert closed == 4
  end

  test "drops what isn't a query", %{port: port} do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, "not dns at all")

    response =
      :inet_dns.encode(
        :inet_dns.make_msg(
          header: :inet_dns.make_header(id: 9, qr: true, opcode: :query),
          qdlist: [:inet_dns.make_dns_query(domain: ~c"example.com", type: :a, class: :in)]
        )
      )

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, response)
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 300)
  end

  @tag cache: [dns_upstreams: [{{127, 0, 0, 1}, 9}]]
  test "a dead upstream is SERVFAIL", %{port: port} do
    assert rcode(resolve(port, "example.com", :a, timeout: 5000)) == :servfail
  end
end
