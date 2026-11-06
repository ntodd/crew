defmodule CrewCache.DNS.BindTest do
  use ExUnit.Case, async: true

  alias CrewCache.DNS.Bind

  @ip {127, 0, 0, 1}
  @udp [:binary, ip: @ip, active: false]
  @tcp [:binary, ip: @ip, active: false, reuseaddr: true]

  test "opens UDP and TCP on the same port" do
    assert {:ok, udp, tcp, port} = Bind.open(0, @udp, @tcp)
    assert {:ok, ^port} = :inet.port(udp)
    assert {:ok, ^port} = :inet.port(tcp)
  end

  # Port 0 lets the OS pick a free UDP port, but that port's TCP side can
  # already be taken. Then it picks again instead of failing.
  test "picks another port when a picked one's TCP side is taken" do
    {:ok, taken} = :gen_tcp.listen(0, ip: @ip)
    {:ok, taken_port} = :inet.port(taken)
    me = self()

    open_udp = fn port, opts ->
      send(me, {:asked, port})

      case Process.get(:tries, 0) do
        0 ->
          Process.put(:tries, 1)
          :gen_udp.open(taken_port, opts)

        _ ->
          :gen_udp.open(port, opts)
      end
    end

    assert {:ok, udp, tcp, port} = Bind.open(0, @udp, @tcp, open_udp)
    assert port != taken_port
    assert {:ok, ^port} = :inet.port(udp)
    assert {:ok, ^port} = :inet.port(tcp)
    assert_received {:asked, 0}
    assert_received {:asked, 0}
  end

  test "a fixed port that's taken is an error, not a different port" do
    {:ok, taken} = :gen_tcp.listen(0, ip: @ip)
    {:ok, taken_port} = :inet.port(taken)

    assert {:error, :eaddrinuse} = Bind.open(taken_port, @udp, @tcp)
  end
end
