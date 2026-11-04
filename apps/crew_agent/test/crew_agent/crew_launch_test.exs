defmodule CrewAgent.CrewLaunchTest do
  @moduledoc """
  `crew-launch` (`packaging/macos/crew-launch`), how launchd starts the
  agent on macOS (§20.2): Foreman's systemd rollback, done for launchd.
  While an update is pending, each start is counted in `agent/crashes`,
  and the third within 120 s switches `current` back to `previous` and
  leaves the marker for the release it lands on to report
  (`CrewAgent.Updater.confirm/2`). Run for real with stand-in releases.
  """
  use ExUnit.Case, async: true

  alias CrewAgent.{Config, Updater}

  @script Path.expand("../../../../packaging/macos/crew-launch", __DIR__)

  setup do
    data = Path.join(System.tmp_dir!(), "crew-launch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data) end)
    agent = Path.join(data, "agent")

    for {version, body} <- [
          {"0.1.0", "echo started 0.1.0 \"$@\""},
          {"0.2.0", "echo crashed 0.2.0; exit 1"}
        ] do
      bin = Path.join([agent, version, "bin"])
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "crew_agent"), "#!/bin/sh\n#{body}\n")
      File.chmod!(Path.join(bin, "crew_agent"), 0o755)
    end

    File.ln_s!("0.2.0", Path.join(agent, "current"))
    File.ln_s!("0.1.0", Path.join(agent, "previous"))
    marker = ~s({"op_id":"0190f0a2-0000-7000-8000-00000000b001","version":"0.2.0","from":"0.1.0"})
    File.write!(Path.join(agent, "update-pending"), marker)
    %{data: data, agent: agent}
  end

  defp launch(ctx),
    do: System.cmd("sh", [@script], env: [{"CREW_DATA_DIR", ctx.data}], stderr_to_stdout: true)

  defp current(ctx), do: File.read_link!(Path.join(ctx.agent, "current"))

  test "runs current's agent, counting starts while an update is pending", ctx do
    assert {"crashed 0.2.0\n", 1} = launch(ctx)
    assert {"crashed 0.2.0\n", 1} = launch(ctx)
    assert current(ctx) == "0.2.0"
    assert ctx.agent |> Path.join("crashes") |> File.read!() |> String.split() |> length() == 2
  end

  test "the third start within 120 s of an update goes back to previous", ctx do
    launch(ctx)
    launch(ctx)
    assert {out, 0} = launch(ctx)
    assert out =~ "rolled back to 0.1.0"
    assert out =~ "started 0.1.0 start"

    assert current(ctx) == "0.1.0"
    refute File.exists?(Path.join(ctx.agent, "previous"))
    refute File.exists?(Path.join(ctx.agent, "update-pending"))
    refute File.exists?(Path.join(ctx.agent, "crashes"))

    # 0.1.0, joining, reports the update failed.
    config = %Config{driver: "vz", data_dir: ctx.data}

    assert {:rolled_back, %{version: "0.2.0", op_id: "0190f0a2-0000-7000-8000-00000000b001"}} =
             Updater.confirm(config, running: "0.1.0")
  end

  test "starts more than 120 s apart don't add up", ctx do
    old = System.os_time(:second) - 300
    File.write!(Path.join(ctx.agent, "crashes"), "#{old}\n#{old + 1}\n")
    launch(ctx)
    assert current(ctx) == "0.2.0"
  end

  test "without an update pending, nothing is counted", ctx do
    File.rm!(Path.join(ctx.agent, "update-pending"))
    File.write!(Path.join(ctx.agent, "crashes"), "1\n2\n")

    for _ <- 1..3, do: launch(ctx)
    assert current(ctx) == "0.2.0"
    refute File.exists?(Path.join(ctx.agent, "crashes"))
  end
end
