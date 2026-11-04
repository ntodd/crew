defmodule Crew.Boxes.LauncherTest do
  @moduledoc """
  The linux-vm and mac-vm launchers (§12.3), as the control plane serves
  them: the running release's, with its pinned Flatcar and vfkit filled in.
  """
  use ExUnit.Case, async: true

  alias Crew.Boxes.{Flatcar, Launcher}

  @url "https://crew.tail1234.ts.net"

  for type <- ["linux-vm", "mac-vm"] do
    test "#{type} has every placeholder filled, and is valid sh" do
      assert {:ok, script} = Launcher.script(unquote(type), @url)
      refute script =~ ~r/__[A-Z0-9_]+__/
      assert script =~ ~s(CREW_URL="#{@url}")
      assert script =~ ~s(FLATCAR_VERSION="#{Flatcar.pins()["FLATCAR_VERSION"]}")

      assert script =~
               "curl -fsSL #{@url}/agent/#{unquote(type)}.sh | sudo sh -s -- --token cj_..."

      path =
        Path.join(
          System.tmp_dir!(),
          "crew-#{unquote(type)}-#{System.unique_integer([:positive])}.sh"
        )

      File.write!(path, script)
      on_exit(fn -> File.rm(path) end)
      assert {_, 0} = System.cmd("sh", ["-n", path], stderr_to_stdout: true)
    end
  end

  test "linux-vm pins Flatcar's images for both arches" do
    {:ok, script} = Launcher.script("linux-vm", @url)
    pins = Flatcar.pins()
    assert script =~ ~s(FLATCAR_IMAGE_SHA512_AMD64="#{pins["FLATCAR_IMAGE_SHA512_AMD64"]}")
    assert script =~ ~s(FLATCAR_IMAGE_SHA512_ARM64="#{pins["FLATCAR_IMAGE_SHA512_ARM64"]}")
    # Two disks, each its own iothread; the Ignition through fw_cfg.
    assert script =~ "file=$DIR/os.img"
    assert script =~ "file=$DIR/data.img"
    assert script =~ "-fw_cfg \"name=opt/org.flatcar-linux/config,file=$DIR/config.ign\""
    assert script =~ "/sys/module/kvm_intel/parameters/nested"
    assert script =~ "DATA=200"
    assert script =~ "DISK=12"
  end

  test "mac-vm pins Flatcar's arm64 image, kernel and /usr, and vfkit" do
    {:ok, script} = Launcher.script("mac-vm", @url)
    pins = Flatcar.pins()

    for key <-
          ~w(FLATCAR_IMAGE_SHA512_ARM64 FLATCAR_KERNEL_SHA512_ARM64 FLATCAR_VERITY_ARM64 FLATCAR_USR_A VFKIT_VERSION VFKIT_SHA256) do
      assert script =~ ~s(#{key}="#{pins[key]}"), key
    end

    assert script =~ "--nested"
    assert script =~ ~s(LAUNCHD="$ROOT/Library/LaunchDaemons")
    assert script =~ ~s(plist="$LAUNCHD/com.crew.hostvm.$1.plist")
    assert script =~ "/Library/Application Support/Crew/hostvm"
    assert script =~ "macOS 15 or later on an M3 or later"
  end

  test "refuses a base URL that could break out of the script" do
    for bad <- [
          ~s(https://crew.example"; reboot; "),
          "https://crew.example/\n$(reboot)",
          "ftp://crew"
        ] do
      assert {:error, :bad_url} = Launcher.script("linux-vm", bad), bad
    end
  end

  test "development URLs are fine" do
    assert {:ok, script} = Launcher.script("mac-vm", "http://192.168.64.1:4100")
    assert script =~ ~s(CREW_URL="http://192.168.64.1:4100")
  end
end
