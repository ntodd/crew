defmodule Crew.Boxes.FlatcarInstallTest do
  @moduledoc """
  The first install the Ignition carries (crew-agent-install, §12.2),
  run for real: the script and files as the Ignition writes them to
  /etc/crew-box, a data directory standing in for /srv/crew, and signed
  fixture tarballs fetched over file:// URLs. It needs sh, curl, tar and
  an openssl with ed25519 (OpenSSL 3).
  """
  use ExUnit.Case, async: true

  import Crew.AgentReleaseFixtures

  alias Crew.Boxes.Flatcar

  setup do
    key = Crew.ImageFixtures.keypair()
    root = tmp_dir("flatcar-install")
    release_dir = Path.join(root, "release")
    files = write_release(release_dir, key, "0.3.0", "linux-arm64")
    data = Path.join(root, "srv-crew")
    File.mkdir_p!(Path.join(data, "agent"))
    %{key: key, root: root, files: files, data: data}
  end

  defp release(files, overrides \\ %{}) do
    Map.merge(
      %{
        version: "0.3.0",
        agent: %{
          url: "file://" <> files["agent"].path,
          sha256: files["agent"].sha256,
          signature: files["agent"].signature
        },
        cache: %{
          url: "file://" <> files["cache"].path,
          sha256: files["cache"].sha256,
          signature: files["cache"].signature
        }
      },
      overrides
    )
  end

  # Writes the Ignition's /etc/crew-box files into a directory.
  defp render_etc(root, key, release) do
    {:ok, config} =
      Flatcar.ignition(%{
        mode: :provision,
        name: "m3max",
        type: "mac-vm",
        arch: "arm64",
        url: "https://crew.tail1234.ts.net",
        join_token: "cj_install-test-token",
        tailscale_auth_key: nil,
        ssh_keys: [],
        release_key: key.public,
        release: release,
        dev: false
      })

    etc = Path.join(root, "etc-crew-box-#{System.unique_integer([:positive])}")
    File.mkdir_p!(etc)

    for %{"path" => "/etc/crew-box/" <> name, "contents" => %{"source" => "data:;base64," <> b64}} <-
          config["storage"]["files"] do
      File.write!(Path.join(etc, name), Base.decode64!(b64))
    end

    etc
  end

  defp install(etc, data) do
    System.cmd("sh", [Path.join(etc, "agent-install.sh")],
      env: [{"CREW_BOX_ETC", etc}, {"CREW_BOX_DATA", data}],
      stderr_to_stdout: true
    )
  end

  test "installs the agent and cache, and writes the agent's settings", ctx do
    etc = render_etc(ctx.root, ctx.key, release(ctx.files))
    assert {out, 0} = install(etc, ctx.data)
    assert out =~ "crew-box: installed the agent 0.3.0"

    agent = Path.join(ctx.data, "agent")
    assert {:ok, "0.3.0"} = File.read_link(Path.join(agent, "current"))
    assert File.read!(Path.join(agent, "0.3.0/bin/crew_agent")) =~ "crew_agent 0.3.0"
    assert File.exists?(Path.join(agent, "0.3.0/bin/crew-vmctl"))
    assert File.exists?(Path.join(agent, "0.3.0/etc/nft.conf"))
    assert File.read!(Path.join(agent, "0.3.0/cache/bin/crew_cache")) =~ "crew_cache 0.3.0"

    env = File.read!(Path.join(agent, "env"))
    assert env =~ "CREW_URL=wss://crew.tail1234.ts.net/agent/websocket\n"
    assert env =~ "CREW_JOIN_TOKEN=cj_install-test-token\n"
    assert env =~ "CREW_BOX_NAME=m3max\n"
    assert env =~ "CREW_DATA_DIR=#{ctx.data}\n"
    assert env =~ "CREW_DRIVER=firecracker\n"
    assert env =~ "CREW_RELEASE_PUBLIC_KEY=#{Base.encode64(ctx.key.public)}\n"
    refute env =~ "CREW_DEV"
    assert File.stat!(Path.join(agent, "env")).mode |> Bitwise.band(0o777) == 0o600

    # Nothing left over, and a second run changes nothing.
    assert agent |> File.ls!() |> Enum.sort() == ["0.3.0", "current", "env"]
    assert {out, 0} = install(etc, ctx.data)
    assert out =~ "the agent is installed (0.3.0)"
  end

  # What root runs comes from a tree the agent can't write (it owns
  # agent/, to update itself), with the units pointed at it.
  test "puts what root runs in root/, outside the agent's reach", ctx do
    etc = render_etc(ctx.root, ctx.key, release(ctx.files))
    assert {_, 0} = install(etc, ctx.data)

    root = Path.join(ctx.data, "root")
    assert {:ok, "0.3.0"} = File.read_link(Path.join(root, "current"))

    for f <- ~w(bin/crew-vmctl bin/jailer bin/firecracker) do
      assert File.read!(Path.join([root, "0.3.0", f])) ==
               File.read!(Path.join([ctx.data, "agent/0.3.0", f]))

      assert Bitwise.band(File.stat!(Path.join([root, "0.3.0", f])).mode, 0o022) == 0, f
    end

    assert File.read!(Path.join(root, "0.3.0/etc/nft.conf")) =~ "table inet crew"
    assert File.exists?(Path.join(root, "0.3.0/etc/connlimit.rules"))

    units = File.ls!(Path.join(root, "0.3.0/etc/systemd")) |> Enum.sort()
    assert units == vmctl_units()

    for unit <- units do
      text = File.read!(Path.join([root, "0.3.0/etc/systemd", unit]))
      refute text =~ "/srv/crew/agent/current/bin/", unit

      for line <- String.split(text, "\n"), line =~ ~r/^Exec/ do
        assert line =~ ~r{=/srv/crew/root/current/bin/crew-vmctl }, "#{unit}: #{line}"
      end
    end
  end

  test "refuses a release without crew-vmctl's units", ctx do
    entries = Enum.reject(agent_entries("0.3.0"), fn {path, _} -> path =~ "crew-net.service" end)
    bytes = tarball(entries)
    File.write!(ctx.files["agent"].path, bytes)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    sig = CrewProtocol.Auth.sign_release("0.3.0", "linux-arm64", sha, ctx.key.private)
    files = ctx.files |> put_in(["agent", :sha256], sha) |> put_in(["agent", :signature], sig)
    etc = render_etc(ctx.root, ctx.key, release(files))

    assert {out, 1} = install(etc, ctx.data)
    assert out =~ "the release has no etc/systemd/crew-net.service"
    refute File.exists?(Path.join(ctx.data, "agent/current"))
    refute File.exists?(Path.join(ctx.data, "root/current"))
  end

  test "refuses a tarball that isn't the one the Ignition names", ctx do
    File.write!(ctx.files["agent"].path, tarball(agent_entries("evil")))
    etc = render_etc(ctx.root, ctx.key, release(ctx.files))

    assert {out, 1} = install(etc, ctx.data)
    assert out =~ "the agent doesn't match its SHA-256"
    refute File.exists?(Path.join(ctx.data, "agent/current"))
    assert File.ls!(Path.join(ctx.data, "agent")) == []
  end

  test "refuses a signature the release key didn't make", ctx do
    other = Crew.ImageFixtures.keypair()

    sig =
      CrewProtocol.Auth.sign_release(
        "0.3.0",
        "linux-arm64",
        ctx.files["cache"].sha256,
        other.private
      )

    files = put_in(ctx.files, ["cache", :signature], sig)
    etc = render_etc(ctx.root, ctx.key, release(files))

    assert {out, 1} = install(etc, ctx.data)
    assert out =~ "the cache's signature doesn't verify against the release key (SHA256:"
    refute File.exists?(Path.join(ctx.data, "agent/current"))
  end

  test "refuses a signature over another target", ctx do
    sig =
      CrewProtocol.Auth.sign_release(
        "0.3.0",
        "linux-amd64",
        ctx.files["agent"].sha256,
        ctx.key.private
      )

    etc = render_etc(ctx.root, ctx.key, release(put_in(ctx.files, ["agent", :signature], sig)))
    assert {out, 1} = install(etc, ctx.data)
    assert out =~ "the agent's signature doesn't verify"
  end

  # crew-format-data's script, with blkid, mkfs.xfs and udevadm stubbed:
  # a crew-data disk under any name is left alone, and with none, the
  # configured device is what's formatted, or nothing is.
  describe "formatting the data disk" do
    setup ctx do
      etc = render_etc(ctx.root, ctx.key, release(ctx.files))
      bin = Path.join(ctx.root, "format-stubs")
      log = Path.join(ctx.root, "format.log")
      File.mkdir_p!(bin)

      for {name, body} <- [
            {"blkid",
             """
             echo "blkid $*" >> "#{log}"
             case "$*" in
               *LABEL=crew-data*) if [ -n "${STUB_LABELLED:-}" ]; then echo "$STUB_LABELLED"; exit 0; fi ;;
             esac
             exit 2
             """},
            {"mkfs.xfs", ~s(echo "mkfs.xfs $*" >> "#{log}"\n)},
            {"udevadm", "exit 0\n"}
          ] do
        File.write!(Path.join(bin, name), "#!/bin/sh\n" <> body)
        File.chmod!(Path.join(bin, name), 0o755)
      end

      %{etc: etc, bin: bin, log: log}
    end

    defp format(ctx, device, env) do
      System.cmd("sh", [Path.join(ctx.etc, "format-data.sh"), device],
        env:
          [
            {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
            {"CREW_BOX_ETC", ctx.etc},
            {"CREW_BOX_DEVICE_WAIT", "2"}
          ] ++ env,
        stderr_to_stdout: true
      )
    end

    test "leaves a crew-data disk alone, whatever it's called now", ctx do
      # Added as /dev/sdb; it's /dev/sdc this boot, and /dev/sdb is gone.
      assert {_, 0} = format(ctx, "/dev/crew-test-sdb", [{"STUB_LABELLED", "/dev/sdc"}])
      refute File.read!(ctx.log) =~ "mkfs.xfs"
    end

    test "with no crew-data disk and no device, formats nothing and says why", ctx do
      assert {out, 1} = format(ctx, "/dev/crew-test-sdb", [])

      assert out =~
               "crew-box: there's no data disk at /dev/crew-test-sdb, and no disk is labelled crew-data"

      refute File.read!(ctx.log) =~ "mkfs.xfs"
    end
  end
end
