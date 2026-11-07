defmodule CrewGuest.FakeAPITest do
  use ExUnit.Case, async: true

  alias CrewGuest.FakeAPI

  setup do
    %{api: start_supervised!(FakeAPI)}
  end

  # Rate-limit tests compare `at` against when the client started a request,
  # so a slow body mustn't push the stamp later.
  test "a request is stamped when it arrives, not when its body is read", %{api: api} do
    body = ~s({"state":"job_started","at":1})
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", FakeAPI.port(api), [:binary, active: false])

    sent = System.monotonic_time(:millisecond)

    :ok =
      :gen_tcp.send(sock, [
        "POST /v1/state HTTP/1.1\r\n",
        "host: 127.0.0.1\r\n",
        "authorization: Bearer t0ken\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\n\r\n"
      ])

    Process.sleep(400)
    :ok = :gen_tcp.send(sock, body)
    assert {:ok, "HTTP/1.1 204" <> _} = :gen_tcp.recv(sock, 0, 1_000)

    assert [req] = FakeAPI.requests(api)
    assert req.bytes == byte_size(body)
    assert req.at - sent < 400
  end
end
