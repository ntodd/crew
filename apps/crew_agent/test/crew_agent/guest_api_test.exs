defmodule CrewAgent.GuestAPITest do
  use ExUnit.Case, async: false

  alias CrewAgent.{GuestAPI, VM}

  # vz (§13.4): one Unix socket per VM, pinned to it. A socket has no
  # peer address, so the failures that drop a source must be counted per
  # socket: one guest guessing tokens mustn't cut every other VM off its
  # guest API (payload, logs, states) for a minute.
  test "on vz, a guest that floods bad tokens is dropped alone, not every VM" do
    # Socket paths are capped at 104 bytes on macOS.
    dir = "/tmp/cga#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    [a, b] =
      for name <- ["a", "b"] do
        vm_id = CrewProtocol.uuid7()
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        :ets.insert(VM.sessions_table(), {:crypto.hash(:sha256, token), vm_id, "10.200.0.2"})
        path = Path.join(dir, "#{name}.sock")
        {:ok, _} = GuestAPI.start_socket(vm_id, path)
        on_exit(fn -> GuestAPI.stop_socket(vm_id) end)
        %{vm_id: vm_id, token: token, path: path}
      end

    get = fn vm, token ->
      Req.get!("http://localhost/v1/payload",
        unix_socket: vm.path,
        auth: {:bearer, token},
        retry: false
      ).status
    end

    # Authenticated, with no VM server behind it: 404.
    assert get.(b, b.token) == 404

    # A guesses: refused, then dropped.
    statuses = for _ <- 1..12, do: get.(a, "guess-#{System.unique_integer()}")
    assert Enum.take(statuses, 10) == List.duplicate(401, 10)
    assert List.last(statuses) == 429
    assert get.(a, a.token) == 429

    # B is unaffected.
    assert get.(b, b.token) == 404
  end
end
