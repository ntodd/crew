defmodule Mix.Tasks.Crew.IgnitionTest do
  @moduledoc "The sample Ignitions CI validates (`mix crew.ignition`), bare metal's two layouts."
  use ExUnit.Case, async: true

  defp render(args) do
    out = Path.join(System.tmp_dir!(), "crew-ignition-#{System.unique_integer([:positive])}.ign")
    Mix.Tasks.Crew.Ignition.run(args ++ ["--out", out])
    config = out |> File.read!() |> Jason.decode!()
    File.rm!(out)
    config
  end

  defp format_unit(config),
    do: Enum.find(config["systemd"]["units"], &(&1["name"] == "crew-format-data.service"))

  test "bare metal is one disk by default" do
    for flags <- [[], ["--layout", "one"], ["--layout", "one", "--reprovision"]] do
      config = render(["--type", "linux-metal"] ++ flags)
      assert [%{"device" => "/dev/disk/by-id/" <> _}] = config["storage"]["disks"]
      assert format_unit(config)["contents"] =~ "--partition /dev/disk/by-id/"
    end
  end

  test "or a separate data disk" do
    config = render(["--type", "linux-metal", "--layout", "separate"])
    refute config["storage"]["disks"]
    assert format_unit(config)["contents"] =~ "format-data.sh /dev/sdb\n"
  end

  test "refuses a layout for anything but bare metal" do
    assert_raise Mix.Error, ~r/--layout is for linux-metal/, fn ->
      render(["--type", "linux-vm", "--layout", "one"])
    end
  end
end
