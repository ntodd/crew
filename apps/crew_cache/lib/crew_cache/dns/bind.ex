defmodule CrewCache.DNS.Bind do
  @moduledoc """
  Opens a DNS listener's UDP socket and TCP listener on one port.

  With port 0 the OS picks a free UDP port, and the TCP side then has to
  take the same number, which something else can already hold. Then both
  are closed and it picks again, up to 20 times. A fixed port (53 on a
  box) is tried once: if it's taken, that's the error.
  """

  @attempts 20

  @spec open(
          :inet.port_number(),
          [:gen_udp.option()],
          [:gen_tcp.listen_option()],
          (:inet.port_number(), [:gen_udp.option()] ->
             {:ok, :gen_udp.socket()} | {:error, term()})
        ) :: {:ok, :gen_udp.socket(), :gen_tcp.socket(), :inet.port_number()} | {:error, term()}
  def open(port, udp_opts, tcp_opts, open_udp \\ &:gen_udp.open/2) do
    attempt(port, udp_opts, tcp_opts, open_udp, if(port == 0, do: @attempts, else: 1))
  end

  defp attempt(port, udp_opts, tcp_opts, open_udp, left) do
    with {:ok, udp} <- open_udp.(port, udp_opts),
         {:ok, bound} <- :inet.port(udp) do
      case :gen_tcp.listen(bound, tcp_opts) do
        {:ok, tcp} ->
          {:ok, udp, tcp, bound}

        {:error, :eaddrinuse} when left > 1 ->
          :gen_udp.close(udp)
          attempt(port, udp_opts, tcp_opts, open_udp, left - 1)

        {:error, _} = error ->
          :gen_udp.close(udp)
          error
      end
    end
  end
end
