defmodule CrewGuest.ReleaseTest do
  # The release's unit and BEAM flags against crew-guest's own stop bounds
  # (§13.5): they're set in three places and only work together.
  use ExUnit.Case, async: true

  alias CrewGuest.Config

  @rel Path.expand("../../rel", __DIR__)

  defp read(name), do: File.read!(Path.join(@rel, name))

  defp unit_setting(key) do
    [_, value] = Regex.run(~r/^#{key}=(\S+)$/m, read("crew-guest.service"))
    value
  end

  test "systemd's SIGTERM goes to crew-guest alone, and its SIGKILL to everything left" do
    assert unit_setting("KillMode") == "mixed"
  end

  test "the runner's grace, the flush, the release's stop and the backstop fit the unit's timeout" do
    cfg = Config.__struct__()
    stop_timeout = String.to_integer(unit_setting("TimeoutStopSec")) * 1_000
    [_, shutdown] = Regex.run(~r/^-shutdown_time (\d+)$/m, read("vm.args.eex"))
    shutdown = String.to_integer(shutdown)
    backstop = CrewGuest.Application.backstop_ms(cfg)

    # The runner's own cancel gives a step 7.5 s after SIGINT before it
    # escalates (actions/runner's ProcessInvoker): either stop allows that.
    assert cfg.sigterm_timeout_ms - cfg.flush_reserve_ms >= 7_500
    assert cfg.flush_timeout_ms - cfg.flush_reserve_ms >= 7_500

    # Then init:stop, capped, or the backstop's halt, before systemd's SIGKILL.
    assert backstop > cfg.sigterm_timeout_ms
    assert cfg.sigterm_timeout_ms + shutdown < stop_timeout
    assert backstop < stop_timeout
  end
end
