defmodule CrewAgent.CrashStatusTest do
  use ExUnit.Case, async: true

  alias CrewAgent.{Config, Connection, Identity, VM}

  test "inspection exposes only operational fields" do
    identity = %Identity{agent_id: "box", private_key: "fixture-private"}
    config = %Config{join_token: "fixture-join", cache_mgmt_token: "fixture-cache"}
    refute inspect({identity, config}) =~ "fixture-"
  end

  test "VM and connection diagnostics allow only operational state" do
    secret = "fixture-private"

    for {mod, state, key} <- [
          {VM, %{vm_id: "vm", payload: %{jit_config: secret}, guest_token: secret}, :vm_id},
          {Connection, %Slipstream.Socket{assigns: %{joined: true, identity: secret}}, :joined}
        ] do
      status =
        mod.format_status(%{
          state: state,
          message: {:command, secret},
          reason: {:badarg, [secret]},
          log: [secret],
          queue: [secret]
        })

      assert Map.has_key?(status.state, key)
      refute inspect(status) =~ secret
    end
  end
end
