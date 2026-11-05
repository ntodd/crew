defmodule CrewGuest.StubRunnerTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  @moduletag :tmp_dir

  # A test that ends without stopping a hanging stub, or a test run that's
  # cut short, mustn't leave its listener polling for good.
  for hang <- ["1", "ignore"] do
    test "with STUB_HANG=#{hang}, the stub ends once whatever started it has gone",
         %{tmp_dir: dir} do
      parent = start_stub(dir, unquote(hang))
      listener = stub_listener(dir)
      {stub, _} = System.cmd("ps", ["-o", "ppid=", "-p", listener])
      stub = String.trim(stub)

      System.cmd("kill", ["-KILL", parent])

      eventually(fn -> not os_alive?(listener) end, 2_000)
      eventually(fn -> not os_alive?(stub) end, 2_000)
    end
  end

  # The stub's parent: a shell that started it and waits for it.
  defp start_stub(dir, hang) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:args, ["-c", ~s("$0" --jitconfig x >/dev/null 2>&1 & wait), fixture("stub-runner")]},
        {:cd, dir},
        {:env, [{~c"STUB_HANG", String.to_charlist(hang)}, {~c"STUB_DELAY", ~c"0.05"}]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Integer.to_string(os_pid)
  end
end
