defmodule CrewAgent.VZIntegrationTest do
  @moduledoc """
  Real VMs on this Mac: the agent's own start path (image, clone, lease,
  guest API socket, vz.json) through a real crew-vzd and crew-vz helper,
  booting crew-vz's test guest in its crew mode, which talks to the
  guest API from inside the VM.

      cd native && make && make guest
      CREW_VZ_BIN=$PWD/native/crew-vz/bin/crew-vz CREW_VZ_GUEST=$PWD/tmp/crew-vz-guest \\
        mix test --only vz
  """
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Config, Handler, Images, VMs}
  alias CrewAgent.Driver.VZ
  alias VZ.Daemon

  @moduletag :vz
  @moduletag timeout: 180_000

  setup_all do
    bin = System.get_env("CREW_VZ_BIN") || raise "CREW_VZ_BIN isn't set"
    guest = System.get_env("CREW_VZ_GUEST") || raise "CREW_VZ_GUEST isn't set"

    # Short: Unix socket paths are capped at 104 bytes on macOS.
    dir = "/private/tmp/cvzi#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.join(dir, "vms"))
    sock = Path.join(dir, "vzd.sock")

    daemon =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "daemon",
          "--socket",
          sock,
          "--data-dir",
          dir,
          "--sandbox",
          Path.expand("../../../../native/crew-vz/sandbox.sb", __DIR__)
        ]
      ])

    wait_for(fn -> File.exists?(sock) end)

    base = Config.get()

    Config.put(%{
      base
      | driver: "vz",
        data_dir: dir,
        vzd_socket: sock,
        dev: true,
        dev_image_dir: guest,
        vz_dns_fallback: "1.1.1.1"
    })

    Application.put_env(:crew_agent, :crew_vz_bin, bin)

    on_exit(fn ->
      Config.put(base)
      Application.delete_env(:crew_agent, :crew_vz_bin)
      with {:os_pid, pid} <- Port.info(daemon, :os_pid), do: System.cmd("kill", [to_string(pid)])
      File.rm_rf!(dir)
    end)

    image_id = CrewProtocol.uuid7()
    :ok = Images.prepare(%{id: image_id, version: "0.0.0-dev", arch: "arm64"})
    %{dir: dir, image_id: image_id}
  end

  setup do
    attach()
    :ok
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(50) && wait_for(fun, tries - 1)
    end
  end

  defp start(image_id) do
    cmd =
      start_command(%{
        "size" => %{"vcpus" => 2, "memory_mib" => 1024, "disk_gib" => 10},
        "image" => %{
          "id" => image_id,
          "version" => "0.0.0-dev",
          "arch" => "arm64",
          "manifest_sha256" => String.duplicate("0", 64)
        }
      })

    assert :ok = Handler.handle(cmd)
    cmd.payload.vm_id
  end

  test "capabilities come from this Mac and a live crew-vzd" do
    {:ok, caps} = VZ.capabilities()
    assert caps.driver == "vz"
    assert caps.firewall_ok
    assert caps.driver_version != "unknown"
  end

  test "a real VM boots, uses the guest API from inside, and stops gracefully", %{
    image_id: image_id
  } do
    vm_id = start(image_id)
    started = System.monotonic_time(:millisecond)

    events =
      collect_until(
        &(&1.type == "vm.state" and &1.payload.vm_id == vm_id and
            &1.payload.state == "runner_listening"),
        60_000
      )

    listening_ms = System.monotonic_time(:millisecond) - started
    IO.puts("\n  a real VM was listening #{listening_ms} ms after vm.start")
    assert Enum.any?(events, &(&1.type == "vm.state" and &1.payload.state == "booted"))
    assert VZ.alive?(vm_id)

    log = await("vm.log", &(&1.vm_id == vm_id), 10_000)
    assert Enum.any?(log.payload.lines, &(&1.text =~ "real VM"))

    # Graceful: through the guest API's control channel, and the power button.
    VMs.stop(vm_id, false, 30)
    exited = await("vm.exited", &(&1.vm_id == vm_id), 30_000)
    assert exited.payload.reason == "poweroff"
    assert exited.payload.cleanup == "ok"
    refute VZ.alive?(vm_id)
  end

  test "a forced stop kills it", %{image_id: image_id} do
    vm_id = start(image_id)
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "runner_listening"), 60_000)
    VMs.stop(vm_id, true, 0)
    exited = await("vm.exited", &(&1.vm_id == vm_id), 15_000)
    assert exited.payload.reason == "killed_stop"
  end

  test "a VM is never launched twice, even with its config and disk put back", %{
    dir: dir,
    image_id: image_id
  } do
    vm_id = start(image_id)
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "runner_listening"), 60_000)
    vm_dir = Path.join([dir, "vms", vm_id])
    config = File.read!(Path.join(vm_dir, "vz.json"))
    VMs.stop(vm_id, true, 0)
    await("vm.exited", &(&1.vm_id == vm_id), 15_000)
    refute File.exists?(Path.join(vm_dir, "rootfs.ext4"))

    File.write!(Path.join(vm_dir, "vz.json"), config)
    {_, 0} = System.cmd("truncate", ["-s", "1G", Path.join(vm_dir, "rootfs.ext4")])
    File.chmod!(Path.join(vm_dir, "rootfs.ext4"), 0o660)

    assert {:error, "already_" <> _, _} =
             Daemon.request(Path.join(dir, "vzd.sock"), %{
               "op" => "start",
               "vm_id" => vm_id,
               "deadline" => System.os_time(:second) + 60
             })
  end
end
