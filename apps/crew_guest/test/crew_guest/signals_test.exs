defmodule CrewGuest.SignalsTest do
  # install/1 and uninstall/0 change the VM's own erl_signal_server.
  use ExUnit.Case, async: false

  alias CrewGuest.Signals

  # SIGTERM is only ever sent to a private event manager here: if the
  # BEAM's own handler got it, it would stop the test run, with status 0.
  defp manager(opts) do
    {:ok, mgr} = :gen_event.start_link()
    :ok = :gen_event.add_handler(mgr, Signals, Map.new(opts))
    mgr
  end

  test "SIGTERM runs on_sigterm" do
    test = self()
    mgr = manager(on_sigterm: fn -> send(test, :sigterm) end)

    :ok = :gen_event.sync_notify(mgr, :sigterm)
    assert_receive :sigterm
  end

  test "if crew-guest is still up at the deadline, it halts, once" do
    test = self()

    mgr =
      manager(
        on_sigterm: fn -> send(test, :sigterm) end,
        deadline_ms: 100,
        on_deadline: fn -> send(test, :halt) end
      )

    :ok = :gen_event.sync_notify(mgr, :sigterm)
    :ok = :gen_event.sync_notify(mgr, :sigterm)
    assert_receive :sigterm
    assert_receive :sigterm
    refute_receive :halt, 50
    assert_receive :halt, 200
    refute_receive :halt, 200
  end

  test "other signals are left to the default handling" do
    test = self()
    mgr = manager(on_sigterm: fn -> send(test, :sigterm) end)

    :ok = :gen_event.sync_notify(mgr, :sighup)
    refute_receive :sigterm, 50
    assert :gen_event.which_handlers(mgr) == [Signals]
  end

  test "install/1 takes SIGTERM over from the BEAM's handler, uninstall/0 gives it back" do
    on_exit(&Signals.uninstall/0)
    assert :erl_signal_handler in :gen_event.which_handlers(:erl_signal_server)

    :ok = Signals.install(on_sigterm: fn -> :ok end)
    :ok = Signals.install(on_sigterm: fn -> :ok end)
    handlers = :gen_event.which_handlers(:erl_signal_server)
    assert Enum.count(handlers, &(&1 == Signals)) == 1
    refute :erl_signal_handler in handlers

    :ok = Signals.uninstall()
    handlers = :gen_event.which_handlers(:erl_signal_server)
    assert :erl_signal_handler in handlers
    refute Signals in handlers
  end
end
