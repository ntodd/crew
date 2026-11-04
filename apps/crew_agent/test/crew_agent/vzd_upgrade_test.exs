defmodule CrewAgent.Driver.VZ.UpgradeTest do
  @moduledoc """
  crew-vzd's update (§20.2): it runs from the agent's release, and is
  asked to restart onto the one `current` points at only once no VM runs.
  Until then the old crew-vzd keeps serving, and its release is kept.
  """
  use ExUnit.Case, async: true

  alias CrewAgent.{Config, FakeVzd, Updater}
  alias CrewAgent.Driver.VZ.Upgrade

  setup do
    data = Path.join("/tmp", "cvu#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data) end)
    agent = Path.join(data, "agent")

    for v <- ~w(0.1.0 0.2.0) do
      File.mkdir_p!(Path.join([agent, v, "bin"]))
      File.write!(Path.join([agent, v, "bin/crew-vz"]), "crew-vz #{v}")
    end

    File.ln_s!("0.2.0", Path.join(agent, "current"))
    sock = Path.join(data, "vzd.sock")
    test = self()
    {:ok, vzd} = Agent.start_link(fn -> "0.1.0" end)

    answer = fn
      %{"op" => "version"} -> %{"ok" => true, "version" => Agent.get(vzd, & &1)}
      %{"op" => "restart"} -> %{"ok" => true}
    end

    start_supervised!({FakeVzd, {sock, answer, test}})
    config = %Config{driver: "vz", data_dir: data, vzd_socket: sock}
    %{config: config, vzd: vzd, agent: agent, memo: :"memo#{System.unique_integer([:positive])}"}
  end

  defp check(ctx, running),
    do: Upgrade.check(ctx.config, running: fn -> running end, memo: ctx.memo)

  test "waits for the last VM to end, then asks crew-vzd to restart onto current", ctx do
    assert :busy = check(ctx, 2)
    assert_received {:vzd, %{"op" => "version"}}
    refute_received {:vzd, %{"op" => "restart"}}

    assert :restarted = check(ctx, 0)
    assert_received {:vzd, %{"op" => "restart"}}

    # Once asked, not again for that version, whatever crew-vzd says.
    assert :ok = check(ctx, 0)
    refute_received {:vzd, %{"op" => "restart"}}
  end

  test "a crew-vzd on current's version is left alone", ctx do
    Agent.update(ctx.vzd, fn _ -> "0.2.0" end)
    assert :ok = check(ctx, 0)
    refute_received {:vzd, %{"op" => "restart"}}
  end

  test "a release without crew-vz (a development install) is left alone", ctx do
    File.rm!(Path.join(ctx.agent, "0.2.0/bin/crew-vz"))
    assert :ok = check(ctx, 0)
    refute_received {:vzd, %{"op" => "restart"}}
  end

  test "crew-vzd's release is kept when old ones are pruned", ctx do
    assert Updater.keep(ctx.config) == ["0.1.0"]
    assert Updater.keep(%{ctx.config | driver: "null"}) == []
  end
end
