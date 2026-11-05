defmodule Crew.Boxes.LauncherInstallTest do
  @moduledoc """
  The launchers' install paths (§12.3), run for real against stubs: the
  machine's paths under a directory of the test's own (`CREW_BOX_ROOT`),
  and stand-ins on PATH for what a Mac or a Linux host would run
  (vfkit, launchctl, hdiutil, sysctl, sw_vers; qemu, systemctl, useradd)
  and for the network (curl serves the control plane and the downloads).
  """
  use ExUnit.Case, async: true

  alias Crew.Boxes.{Flatcar, Launcher}

  @url "http://crew.test"

  setup do
    root = Crew.AgentReleaseFixtures.tmp_dir("launcher-root")
    bin = Path.join(root, "stubs")
    state = Path.join(root, "state")
    File.mkdir_p!(bin)
    File.mkdir_p!(state)

    # What curl hands out: Flatcar's image and kernel, and vfkit.
    image = Path.join(state, "image.bin")
    File.write!(image, :binary.copy("flatcar", 4096))
    {_, 0} = System.cmd("bzip2", ["-k", image])
    kernel = Path.join(state, "vmlinuz")
    File.write!(kernel, "a kernel")
    File.write!(Path.join(state, "ignition.json"), ~s({"ignition":{"version":"3.4.0"}}))

    %{root: root, bin: bin, state: state, image: image <> ".bz2", kernel: kernel}
  end

  defp stub(ctx, name, body) do
    path = Path.join(ctx.bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp sha(path, bits), do: :crypto.hash(bits, File.read!(path)) |> Base.encode16(case: :lower)

  # curl: the control plane (the Ignition, the launcher) and downloads.
  defp stub_curl(ctx, served) do
    cases =
      Enum.map_join(served, "\n", fn {pattern, file} ->
        ~s|  #{pattern}) cp "#{file}" "$out" ;;|
      end)

    stub(ctx, "curl", """
    out="" hdr="" fmt="" url=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out=$2; shift 2 ;;
        -D) hdr=$2; shift 2 ;;
        -w) fmt=$2; shift 2 ;;
        -X | --max-time | --retry | --retry-delay | --unix-socket) shift 2 ;;
        --data-urlencode) echo "data $2" >> "#{ctx.state}/curl.log"; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
      esac
    done
    echo "get $url" >> "#{ctx.state}/curl.log"
    case "$url" in
      */agent/flatcar/ignition)
        code=${STUB_IGNITION_CODE:-200}
        if [ "$code" = 200 ]; then cp "#{ctx.state}/ignition.json" "$out"; else echo '{"error":"join token is invalid"}' > "$out"; fi
        printf 'HTTP/1.1 %s OK\\r\\nX-Crew-Box: devbox\\r\\n\\r\\n' "$code" > "$hdr"
        [ -z "$fmt" ] || printf '%s' "$code"
        exit 0 ;;
      */agent/flatcar/cachevm/ignition)
        code=${STUB_IGNITION_CODE:-200}
        if [ "$code" = 200 ]; then cp "#{ctx.state}/ignition.json" "$out"; else echo '{"error":"only a mac-vz box has a cache VM"}' > "$out"; fi
        printf 'HTTP/1.1 %s OK\\r\\nX-Crew-Box: m1ultra\\r\\nX-Crew-Cache-Token: cm_cache-token-0123456789abcdef0123456789\\r\\n\\r\\n' "$code" > "$hdr"
        [ -z "$fmt" ] || printf '%s' "$code"
        exit 0 ;;
      */agent/*.sh) echo '#!/bin/sh' > "$out" ;;
    #{cases}
      *) echo "curl stub: no $url" >&2; exit 22 ;;
    esac
    """)
  end

  describe "mac-vm.sh" do
    setup ctx do
      vfkit =
        stub(ctx, "vfkit-served", """
        echo "$*" >> "#{ctx.state}/vfkit.log"
        # The prep boot stages the config and powers off.
        for a in "$@"; do
          case "$a" in *logFilePath=*) log=${a#*logFilePath=} ;; esac
        done
        case "$*" in *--kernel*) echo "crew-box: config staged" >> "$log" ;; esac
        exit 0
        """)

      {:ok, script} = Launcher.script("mac-vm", @url)
      pins = Flatcar.pins()

      script =
        script
        |> String.replace(pins["FLATCAR_IMAGE_SHA512_ARM64"], sha(ctx.image, :sha512))
        |> String.replace(pins["FLATCAR_KERNEL_SHA512_ARM64"], sha(ctx.kernel, :sha512))
        |> String.replace(pins["VFKIT_SHA256"], sha(vfkit, :sha256))

      launcher = Path.join(ctx.state, "mac-vm.sh")
      File.write!(launcher, script)

      stub_curl(ctx, [
        {"*/vfkit", vfkit},
        {"*/flatcar_production_image.bin.bz2", ctx.image},
        {"*/flatcar_production_image.vmlinuz", ctx.kernel}
      ])

      stub(ctx, "uname", ~s|case "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n|)
      stub(ctx, "id", ~s(if [ "$1" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi\n))
      stub(ctx, "sw_vers", "echo 15.1\n")

      stub(ctx, "sysctl", """
      case "$2" in
        machdep.cpu.brand_string) echo "${STUB_CHIP:-Apple M3 Max}" ;;
        hw.ncpu) echo 16 ;;
        hw.memsize) echo 68719476736 ;;
      esac
      """)

      # Loading a box's job boots it, and the box enrolls.
      stub(ctx, "launchctl", """
      echo "launchctl $*" >> "#{ctx.state}/launchctl.log"
      case "$1" in
        print) exit 1 ;;
        bootstrap)
          box=$(sed -n 's|.*<key>StandardOutPath</key><string>\\(.*\\)/vfkit.log</string>.*|\\1|p' "$3")
          echo "crew-box: enrolled" >> "$box/serial.log"
          echo "crew-box: cache ready" >> "$box/serial.log" ;;
      esac
      """)

      stub(ctx, "hdiutil", ~s(while [ $# -gt 1 ]; do [ "$1" = -o ] && : > "$2"; shift; done\n))
      stub(ctx, "cpio", "cat > /dev/null\n")
      stub(ctx, "pmset", "echo 'sleep 0'\n")
      stub(ctx, "chown", "exit 0\n")
      File.mkdir_p!(Path.join(ctx.root, "Library/LaunchDaemons"))
      %{launcher: launcher}
    end

    defp mac_install(ctx, env \\ []) do
      System.cmd(
        "sh",
        [ctx.launcher, "--token", "cj_test", "--cpus", "2", "--memory", "4", "--data", "100"],
        env:
          [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"CREW_BOX_ROOT", ctx.root}] ++ env,
        stderr_to_stdout: true
      )
    end

    test "a first install makes the box and its LaunchDaemon", ctx do
      {out, status} = mac_install(ctx)
      assert status == 0, out
      assert out =~ "crew-box: done: devbox is on the Boxes page in Crew"

      box = Path.join(ctx.root, "Library/Application Support/Crew/hostvm/devbox")

      for f <- ~w(os.img data.img box.conf id_ed25519 id_ed25519.pub),
          do: assert(File.exists?(Path.join(box, f)), f)

      assert File.read!(Path.join(box, "box.conf")) =~ "data=100"

      plist =
        File.read!(Path.join(ctx.root, "Library/LaunchDaemons/com.crew.hostvm.devbox.plist"))

      assert plist =~ "<string>run</string><string>devbox</string>"
      assert File.read!(Path.join(ctx.state, "launchctl.log")) =~ "launchctl bootstrap system"
      assert {:ok, _} = File.read_link(Path.join(ctx.root, "usr/local/bin/crew-box"))

      curl = File.read!(Path.join(ctx.state, "curl.log"))
      assert curl =~ "data arch=arm64"
      assert curl =~ "data ssh_keys[]=ssh-ed25519 "
      # Nothing of the install's own is left: the config went to the OS disk.
      refute File.exists?(Path.join(box, "config.ign"))
    end

    defp cache_install(ctx, env \\ []) do
      System.cmd("sh", [ctx.launcher, "--role", "cache", "--token", "cj_test"],
        env:
          [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"CREW_BOX_ROOT", ctx.root}] ++ env,
        stderr_to_stdout: true
      )
    end

    # The launcher is crew-box (the stub control plane serves an empty one).
    defp crew_box(ctx, args) do
      System.cmd("sh", [ctx.launcher | args],
        env: [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"CREW_BOX_ROOT", ctx.root}],
        stderr_to_stdout: true
      )
    end

    test "--role cache makes a mac-vz box's cache VM, on any Apple silicon", ctx do
      {out, status} = cache_install(ctx, [{"STUB_CHIP", "Apple M1 Ultra"}])
      assert status == 0, out
      assert out =~ "crew-box: cache ready"
      assert out =~ "crew-box: done: m1ultra's cache VM is up"

      box = Path.join(ctx.root, "Library/Application Support/Crew/hostvm/cachevm")
      conf = File.read!(Path.join(box, "box.conf"))
      assert conf =~ "name=cachevm\n"
      assert conf =~ "role=cache\n"
      assert conf =~ "cpus=2\n"
      assert conf =~ "memory=4\n"
      assert conf =~ ~r/^mac=52:54:00(:[0-9a-f]{2}){3}$/m

      # The management token, for the box's agent, root's alone.
      token = Path.join(box, "mgmt-token")
      assert File.read!(token) == "cm_cache-token-0123456789abcdef0123456789\n"
      assert Bitwise.band(File.stat!(token).mode, 0o777) == 0o600

      curl = File.read!(Path.join(ctx.state, "curl.log"))
      assert curl =~ "get http://crew.test/agent/flatcar/cachevm/ignition"
      refute curl =~ "data arch="

      assert File.exists?(
               Path.join(ctx.root, "Library/LaunchDaemons/com.crew.hostvm.cachevm.plist")
             )
    end

    test "the cache VM boots without nested virtualization", ctx do
      {_, 0} = cache_install(ctx)
      File.write!(Path.join(ctx.state, "vfkit.log"), "")
      {out, _} = crew_box(ctx, ["run", "cachevm"])
      args = File.read!(Path.join(ctx.state, "vfkit.log"))
      assert args =~ "--restful-uri", out
      refute args =~ "--nested"
    end

    test "restart --role cache --trigger restarts it once, for the agent's request", ctx do
      {_, 0} = cache_install(ctx)
      trigger = Path.join(ctx.root, "restart-cachevm")
      File.write!(Path.join(ctx.state, "launchctl.log"), "")

      # launchd also runs it when the file goes away: then it does nothing.
      assert {_, 0} = crew_box(ctx, ["restart", "--role", "cache", "--trigger", trigger])
      refute File.read!(Path.join(ctx.state, "launchctl.log")) =~ "bootstrap"

      File.write!(trigger, "c1c1c1c1-1111-4111-8111-111111111111\n")
      assert {out, 0} = crew_box(ctx, ["restart", "--role", "cache", "--trigger", trigger])
      refute File.exists?(trigger)
      log = File.read!(Path.join(ctx.state, "launchctl.log"))
      assert log =~ "bootstrap system", out
      assert log =~ "com.crew.hostvm.cachevm"
    end

    test "a token that isn't a mac-vz box's gets no cache VM, and leaves nothing", ctx do
      {out, status} = cache_install(ctx, [{"STUB_IGNITION_CODE", "400"}])
      assert status == 1
      assert out =~ "Crew said 400"
      refute File.exists?(Path.join(ctx.root, "Library/Application Support/Crew"))
    end

    test "a bad token fails before anything is downloaded, and leaves nothing", ctx do
      {out, status} = mac_install(ctx, [{"STUB_IGNITION_CODE", "401"}])
      assert status == 1
      assert out =~ "Crew said 401"
      refute File.exists?(Path.join(ctx.root, "Library/Application Support/Crew"))
      refute File.read!(Path.join(ctx.state, "curl.log")) =~ "vfkit"
    end
  end

  describe "linux-vm.sh" do
    setup ctx do
      {:ok, script} = Launcher.script("linux-vm", @url)

      script =
        String.replace(
          script,
          Flatcar.pins()["FLATCAR_IMAGE_SHA512_AMD64"],
          sha(ctx.image, :sha512)
        )

      launcher = Path.join(ctx.state, "linux-vm.sh")
      File.write!(launcher, script)

      # The machine: KVM with nested virtualization, OVMF, 32 GB.
      for {path, body} <- [
            {"sys/module/kvm_intel/parameters/nested", "Y\n"},
            {"proc/cpuinfo", "vendor_id : GenuineIntel\n"},
            {"proc/meminfo", "MemTotal:       32000000 kB\n"},
            {"proc/cmdline", "root=/dev/sda1\n"},
            {"usr/share/OVMF/OVMF_CODE_4M.fd", "code"},
            {"usr/share/OVMF/OVMF_VARS_4M.fd", "vars"}
          ] do
        File.mkdir_p!(Path.dirname(Path.join(ctx.root, path)))
        File.write!(Path.join(ctx.root, path), body)
      end

      File.mkdir_p!(Path.join(ctx.root, "dev"))
      File.ln_s!("/dev/null", Path.join(ctx.root, "dev/kvm"))
      File.mkdir_p!(Path.join(ctx.root, "etc/systemd/system"))
      File.mkdir_p!(Path.join(ctx.root, "usr/local/sbin"))

      stub_curl(ctx, [{"*/flatcar_production_image.bin.bz2", ctx.image}])
      stub(ctx, "uname", ~s|case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n|)

      stub(ctx, "id", """
      case "$1" in
        -u) echo 0 ;;
        crew-box) [ -e "#{ctx.state}/user" ] ;;
        *) exec /usr/bin/id "$@" ;;
      esac
      """)

      stub(ctx, "useradd", ~s(touch "#{ctx.state}/user"\n))
      stub(ctx, "usermod", "exit 0\n")
      stub(ctx, "userdel", "exit 0\n")
      stub(ctx, "getent", "exit 0\n")
      stub(ctx, "nproc", "echo 8\n")
      stub(ctx, "chown", "exit 0\n")
      stub(ctx, "setpriv", "exit 1\n")
      stub(ctx, "timeout", "shift; exec \"$@\"\n")
      stub(ctx, "qemu-system-x86_64", "exit 0\n")
      stub(ctx, "journalctl", "exit 0\n")
      stub(ctx, "apt-get", ~s(echo "apt-get stub: not expected" >&2; exit 1\n))
      # GNU dd's flags aren't BSD's: the stub just copies.
      stub(ctx, "dd", ~s|for a in "$@"; do case "$a" in of=*) cat > "${a#of=}" ;; esac; done\n|)
      # install -o and -g need root.
      stub(ctx, "install", """
      set --  $(for a in "$@"; do printf '%s\\n' "$a"; done | awk 'skip { skip = 0; next } $0 == "-o" || $0 == "-g" { skip = 1; next } { print }')
      exec /usr/bin/install "$@"
      """)

      # Starting the box boots it, and it enrolls.
      stub(ctx, "systemctl", """
      echo "systemctl $*" >> "#{ctx.state}/systemctl.log"
      case "$1" in
        restart | start) echo "crew-box: enrolled" >> "$STUB_BOX_DIR/serial.log" ;;
      esac
      exit 0
      """)

      %{launcher: launcher, box: Path.join(ctx.root, "var/lib/crew-box")}
    end

    defp linux_install(ctx, env \\ []) do
      System.cmd(
        "sh",
        [ctx.launcher, "--token", "cj_test", "--cpus", "2", "--memory", "4", "--data", "100"],
        env:
          [
            {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
            {"CREW_BOX_ROOT", ctx.root},
            {"STUB_BOX_DIR", ctx.box}
          ] ++ env,
        stderr_to_stdout: true
      )
    end

    test "a first install makes the box and its unit", ctx do
      {out, status} = linux_install(ctx)
      assert status == 0, out
      assert out =~ "crew-box: done: devbox is on the Boxes page in Crew"

      for f <- ~w(os.img data.img box.conf efi-vars.fd id_ed25519),
          do: assert(File.exists?(Path.join(ctx.box, f)), f)

      assert File.read!(Path.join(ctx.box, "box.conf")) =~ "data=100"
      unit = File.read!(Path.join(ctx.root, "etc/systemd/system/crew-box.service"))
      assert unit =~ "ExecStart=#{ctx.root}/usr/local/sbin/crew-box run"
      assert File.exists?(Path.join(ctx.root, "usr/local/sbin/crew-box"))
      assert File.read!(Path.join(ctx.state, "curl.log")) =~ "data arch=amd64"
      # Spent: the token and the Tailscale key.
      refute File.exists?(Path.join(ctx.box, "config.ign"))
    end

    test "a bad token fails before anything is downloaded, and leaves nothing", ctx do
      {out, status} = linux_install(ctx, [{"STUB_IGNITION_CODE", "401"}])
      assert status == 1
      assert out =~ "Crew said 401"
      refute File.exists?(ctx.box)
      refute File.exists?(Path.join(ctx.root, "etc/systemd/system/crew-box.service"))
      refute File.exists?(Path.join(ctx.root, "usr/local/sbin/crew-box"))
      refute File.read!(Path.join(ctx.state, "curl.log")) =~ "flatcar_production_image"
    end

    # The installer may be gone (a closed terminal, its 10 minutes up)
    # when the box enrolls: the box's own service deletes the config, with
    # the join token and the Tailscale key, while the box keeps running.
    test "the box's service deletes the first-boot config once the box has enrolled", ctx do
      qemu =
        stub(ctx, "qemu-enrolls", """
        for a in "$@"; do case "$a" in *path=*serial.log) log=${a##*path=} ;; esac; done
        sleep 1
        echo "crew-box: enrolled" >> "$log"
        sleep 8
        """)

      File.mkdir_p!(ctx.box)

      File.write!(Path.join(ctx.box, "box.conf"), """
      name=devbox
      cpus=2
      memory=4
      mac=52:54:00:00:00:01
      ssh_port=2222
      qemu=#{qemu}
      firmware=/nonexistent/OVMF_CODE.fd
      aio=threads
      """)

      config = Path.join(ctx.box, "config.ign")
      File.write!(config, ~s({"ignition":{"version":"3.4.0"}}))

      run =
        Task.async(fn ->
          System.cmd("sh", [ctx.launcher, "run"],
            env: [{"CREW_BOX_DIR", ctx.box}],
            stderr_to_stdout: true
          )
        end)

      deadline = System.monotonic_time(:millisecond) + 7_000

      gone =
        Stream.repeatedly(fn -> Process.sleep(200) end)
        |> Enum.find_value(fn _ ->
          cond do
            not File.exists?(config) -> true
            System.monotonic_time(:millisecond) > deadline -> false
            true -> nil
          end
        end)

      assert gone, "config.ign was still there with the box enrolled and running"
      assert {_, 0} = Task.await(run, 15_000)
    end

    test "refuses a host without nested virtualization, and says how to turn it on", ctx do
      File.write!(Path.join(ctx.root, "sys/module/kvm_intel/parameters/nested"), "N\n")
      {out, 1} = linux_install(ctx)
      assert out =~ "options kvm_intel nested=1"
    end
  end
end
