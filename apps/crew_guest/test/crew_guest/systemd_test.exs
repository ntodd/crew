defmodule CrewGuest.SystemdTest do
  use ExUnit.Case, async: true

  alias CrewGuest.Systemd

  test "sends the message to NOTIFY_SOCKET as one datagram" do
    # sun_path is short, so this can't live under the project's tmp dir.
    path = Path.join(System.tmp_dir!(), "crew-notify-#{System.unique_integer([:positive])}")
    {:ok, sock} = :socket.open(:local, :dgram, :default)
    :ok = :socket.bind(sock, %{family: :local, path: path})
    on_exit(fn -> File.rm(path) end)

    assert :ok = Systemd.notify("READY=1", path)
    assert {:ok, "READY=1"} = :socket.recv(sock, 0, 1_000)
  end

  test "does nothing without a socket" do
    assert :ok = Systemd.notify("READY=1", nil)
    assert :ok = Systemd.notify("READY=1", "")
  end

  test "a socket that isn't there isn't fatal" do
    assert {:error, _} = Systemd.notify("READY=1", "/nonexistent/notify")
  end
end
