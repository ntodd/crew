defmodule CrewAgent.DiskWatchdogTest do
  use ExUnit.Case, async: false
  alias CrewAgent.{Config, DiskWatchdog}

  @tag :tmp_dir
  test "two concurrent Mac starts cannot reserve the same free space", %{tmp_dir: tmp} do
    config = %{Config.get() | driver: "vz", data_dir: tmp}
    File.mkdir_p!(Config.vms_dir(config))
    {_, pid} = start_supervised({DiskWatchdog, name: nil, disk: fn _ -> {40_000, 10_240} end})
    cmd = fn -> GenServer.call(pid, {:reserve, config, CrewProtocol.uuid7(), 6}) end
    assert :ok = cmd.()
    assert {:error, :no_capacity} = cmd.()
  end

  @tag :tmp_dir
  test "under five percent free the watchdog signals only the largest allocated clone", %{
    tmp_dir: tmp
  } do
    config = %{Config.get() | data_dir: tmp}

    ids =
      for blocks <- [1, 64] do
        id = CrewProtocol.uuid7()
        dir = Config.vm_dir(config, id)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "rootfs.ext4"), :crypto.strong_rand_bytes(4096 * blocks))
        {:ok, _} = Registry.register(CrewAgent.Registry, {:vm, id}, nil)
        id
      end

    free = fn _ -> {100, 4} end
    DiskWatchdog.check_clones(config, free)
    assert_receive {:kill_disk, largest}
    assert largest == List.last(ids)
    refute_received {:kill_disk, _}
    DiskWatchdog.check_clones(config, fn _ -> {100, 5} end)
    DiskWatchdog.check_clones(config, fn _ -> {0, 0} end)
    refute_received {:kill_disk, _}
  end
end
