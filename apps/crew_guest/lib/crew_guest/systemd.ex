defmodule CrewGuest.Systemd do
  @moduledoc """
  `sd_notify(3)` without a NIF: one datagram on the Unix socket in
  `NOTIFY_SOCKET`. crew-guest's unit is `Type=notify` (§13.5), so systemd
  holds back the units ordered after it (Docker) until crew-guest says
  `READY=1`.
  """

  require Logger

  @spec notify(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def notify(message, socket \\ System.get_env("NOTIFY_SOCKET"))
  def notify(_message, nil), do: :ok
  def notify(_message, ""), do: :ok

  def notify(message, socket) do
    # A leading "@" is the abstract namespace.
    path = with "@" <> name <- socket, do: <<0, name::binary>>

    with {:ok, sock} <- :socket.open(:local, :dgram, :default) do
      result = :socket.sendto(sock, message, %{family: :local, path: path})
      :socket.close(sock)

      case result do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.warning("crew-guest: couldn't notify systemd: #{inspect(reason)}")
          error
      end
    end
  end
end
