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
  defp render_etc(root, key, release, overrides \\ %{}) do
    {:ok, config} =
      Flatcar.ignition(
        Map.merge(
          %{
            mode: :provision,
            name: "m3max",
            type: "linux-vm",
            arch: "arm64",
            url: "https://crew.tail1234.ts.net",
            join_token: "cj_install-test-token",
            tailscale_auth_key: nil,
            ssh_keys: [],
            release_key: key.public,
            release: release,
            dev: false
          },
          overrides
        )
      )

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
    # The box cache (crew-cache.service) is managed on loopback (§15.8).
    assert env =~ "CREW_CACHE_MGMT_URL=http://127.0.0.1:7780\n"
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

  # crew-format-data's script, with blkid, blockdev, wipefs, mkfs.xfs and
  # udevadm stubbed. blkid finds a crew-data disk with STUB_LABELLED and
  # probes STUB_PROBE's lines on any device; blockdev's size is STUB_SIZE.
  defp format_stubs(root) do
    bin = Path.join(root, "format-stubs")
    log = Path.join(root, "format.log")
    File.mkdir_p!(bin)
    File.write!(log, "")

    for {name, body} <- [
          {"blkid",
           """
           echo "blkid $*" >> "#{log}"
           case "$*" in
             *LABEL=crew-data*) if [ -n "${STUB_LABELLED:-}" ]; then echo "$STUB_LABELLED"; exit 0; fi ;;
             -p*) if [ -n "${STUB_PROBE:-}" ]; then
                    case "$*" in
                      *"-s LABEL -o value"*) printf '%s\n' "$STUB_PROBE" | sed -n 's/^LABEL=//p' ;;
                      *) printf '%s\n' "$STUB_PROBE" ;;
                    esac
                    exit 0
                  fi ;;
           esac
           exit 2
           """},
          {"blockdev", ~s(echo "blockdev $*" >> "#{log}"\necho "${STUB_SIZE:?}"\n)},
          {"wipefs", ~s(echo "wipefs $*" >> "#{log}"\n[ -z "${STUB_WIPEFS_FAILS:-}" ]\n)},
          {"mkfs.xfs", ~s(echo "mkfs.xfs $*" >> "#{log}"\n[ -z "${STUB_MKFS_FAILS:-}" ]\n)},
          {"sync", ~s(echo "sync $*" >> "#{log}"\n)},
          {"udevadm", "exit 0\n"}
        ] do
      File.write!(Path.join(bin, name), "#!/bin/sh\n" <> body)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    %{bin: bin, log: log}
  end

  defp format(ctx, args, env) do
    System.cmd("sh", [Path.join(ctx.etc, "format-data.sh") | List.wrap(args)],
      env:
        [
          {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
          {"CREW_BOX_ETC", ctx.etc},
          {"CREW_BOX_DEVICE_WAIT", "2"}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  # A crew-data disk under any name is left alone, and with none, the
  # configured device is what's formatted, or nothing is.
  describe "formatting the data disk" do
    setup ctx do
      Map.put(format_stubs(ctx.root), :etc, render_etc(ctx.root, ctx.key, release(ctx.files)))
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

  # A one-disk box's partition 10 (§12.2), a regular file standing in for
  # it (CREW_BOX_FAKE_DEVICES): its first boot formats it whatever is on
  # it, and nothing after that ever does.
  describe "formatting a one-disk box's data partition" do
    # A 2 TB disk's partition 10: 1,875,350 MiB and a bit.
    @size 1_966_446_919_168

    setup ctx do
      opts = %{
        type: "linux-metal",
        disk_layout: "one",
        os_disk: "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNJ0W"
      }

      etc = render_etc(ctx.root, ctx.key, release(ctx.files), opts)
      part = Path.join(ctx.root, "part10")
      File.write!(part, "")

      Map.merge(format_stubs(ctx.root), %{etc: etc, part: part})
    end

    defp format_partition(ctx, env) do
      format(ctx, ["--partition", ctx.part], [{"CREW_BOX_FAKE_DEVICES", "1"} | env])
    end

    defp fresh?(ctx), do: File.exists?(Path.join(ctx.etc, "fresh-data"))

    test "a first boot formats it, 16 MiB short of its end", ctx do
      assert fresh?(ctx)
      assert {out, 0} = format_partition(ctx, [{"STUB_SIZE", "#{@size}"}])
      assert out =~ "crew-box: formatting the data partition #{ctx.part}"

      log = File.read!(ctx.log)
      assert log =~ "wipefs -a #{ctx.part}"

      assert log =~
               "mkfs.xfs -q -K -f -L crew-data -m reflink=1 -d size=#{div(@size, 1_048_576) - 16}m #{ctx.part}"

      # wipefs first: mkfs.xfs mustn't find anything to refuse.
      assert :binary.match(log, "wipefs") < :binary.match(log, "mkfs.xfs")
      refute fresh?(ctx)
      # The marker's deletion is on disk before the box writes anything:
      # back after a power cut, it would format the box's data.
      assert log =~ ~r/mkfs\.xfs .*\nsync/
    end

    # The partition outlives a reinstall: a machine added again has the
    # box it was on it, which it mustn't come back as.
    test "a first boot formats it even when it's an old box's", ctx do
      env = [
        {"STUB_SIZE", "#{@size}"},
        {"STUB_LABELLED", ctx.part},
        {"STUB_PROBE", "LABEL=crew-data\nTYPE=xfs"}
      ]

      assert {_, 0} = format_partition(ctx, env)
      assert File.read!(ctx.log) =~ "mkfs.xfs"
      refute fresh?(ctx)
    end

    for {what, env, says} <- [
          {"wipefs", "STUB_WIPEFS_FAILS", "couldn't wipe the data partition"},
          {"mkfs.xfs", "STUB_MKFS_FAILS", "couldn't format the data partition"}
        ] do
      test "a first boot says why when #{what} fails, and keeps the marker", ctx do
        env = [{"STUB_SIZE", "#{@size}"}, {unquote(env), "1"}]
        assert {out, 1} = format_partition(ctx, env)
        assert out =~ "crew-box: #{unquote(says)} #{ctx.part}"
        assert fresh?(ctx)
      end
    end

    test "a first boot refuses a disk under 128 GiB", ctx do
      # A "128 GB" disk: 119 GiB, so a partition 10 of 87 GiB.
      size = 128_000_000_000 - 32 * 1_073_741_824

      assert {out, 1} = format_partition(ctx, [{"STUB_SIZE", "#{size}"}])
      assert out =~ "crew-box: the OS disk is under 128 GiB"
      log = File.read!(ctx.log)
      refute log =~ "wipefs"
      refute log =~ "mkfs.xfs"
    end

    test "a first boot takes a disk of 128 GiB", ctx do
      # Partition 10 ends at the last usable sector, 33 short of the end.
      size = 96 * 1_073_741_824 - 33 * 512
      assert {_, 0} = format_partition(ctx, [{"STUB_SIZE", "#{size}"}])
      assert File.read!(ctx.log) =~ "mkfs.xfs"
    end

    test "after that, keeps its crew-data filesystem", ctx do
      File.rm!(Path.join(ctx.etc, "fresh-data"))
      env = [{"STUB_PROBE", "LABEL=crew-data\nTYPE=xfs"}, {"STUB_SIZE", "#{@size}"}]

      assert {_, 0} = format_partition(ctx, env)
      log = File.read!(ctx.log)
      refute log =~ "wipefs"
      refute log =~ "mkfs.xfs"
    end

    # A reprovision whose partition 10 lost its filesystem: formatting it
    # would make a box with no identity under the old one's name.
    for {what, probe} <- [{"nothing", []}, {"another filesystem", ["LABEL=data\nTYPE=ext4"]}] do
      test "after that, never formats it, even with #{what} on it", ctx do
        File.rm!(Path.join(ctx.etc, "fresh-data"))
        env = [{"STUB_SIZE", "#{@size}"} | Enum.map(unquote(probe), &{"STUB_PROBE", &1})]

        assert {out, 1} = format_partition(ctx, env)

        assert out =~
                 "crew-box: the data partition #{ctx.part} has no crew-data filesystem"

        assert out =~ "add the box again"
        log = File.read!(ctx.log)
        refute log =~ "wipefs"
        refute log =~ "mkfs.xfs"
      end
    end

    test "says so when the partition isn't there", ctx do
      File.rm!(ctx.part)
      assert {out, 1} = format_partition(ctx, [{"STUB_SIZE", "#{@size}"}])
      assert out =~ "crew-box: there's no data partition at #{ctx.part}"
      refute File.read!(ctx.log) =~ "mkfs.xfs"
      assert fresh?(ctx)
    end
  end
end
