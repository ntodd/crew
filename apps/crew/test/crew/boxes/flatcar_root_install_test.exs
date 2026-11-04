defmodule Crew.Boxes.FlatcarRootInstallTest do
  @moduledoc """
  An agent update's root half on a Flatcar box (§10.8, §20.2), run for
  real: crew-root-install's script and the rollback unit's, with the
  files the Ignition writes to /etc/crew-box, a data directory standing
  in for /srv/crew, and `systemctl` stubbed. The agent stages the
  tarballs and a request in `agent/update/` (`CrewAgent.Updater.RootStep`
  writes the same format); root checks them against its own copy of the
  release key and answers in `root/update.result`.
  """
  use ExUnit.Case, async: true

  import Crew.AgentReleaseFixtures

  alias Crew.Boxes.Flatcar

  setup do
    key = Crew.ImageFixtures.keypair()
    root = tmp_dir("flatcar-root-install")
    files = write_release(Path.join(root, "release"), key, "0.3.0", "linux-arm64")

    release = %{
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
    }

    {:ok, config} =
      Flatcar.ignition(%{
        mode: :provision,
        name: "m3max",
        type: "mac-vm",
        arch: "arm64",
        url: "https://crew.tail1234.ts.net",
        join_token: "cj_root-install-test",
        ssh_keys: [],
        release_key: key.public,
        release: release,
        dev: false
      })

    etc = Path.join(root, "etc-crew-box")
    File.mkdir_p!(etc)

    for %{"path" => "/etc/crew-box/" <> name, "contents" => %{"source" => "data:;base64," <> b64}} <-
          config["storage"]["files"],
        do: File.write!(Path.join(etc, name), Base.decode64!(b64))

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    log = Path.join(root, "systemctl.log")
    File.write!(Path.join(bin, "systemctl"), ~s(#!/bin/sh\necho "systemctl $*" >> "#{log}"\n))
    File.chmod!(Path.join(bin, "systemctl"), 0o755)

    data = Path.join(root, "srv-crew")
    File.mkdir_p!(Path.join(data, "agent"))
    units = Path.join(root, "systemd-system")
    File.mkdir_p!(units)

    ctx = %{key: key, root: root, etc: etc, data: data, bin: bin, log: log, units: units}
    assert {_, 0} = sh(ctx, "agent-install.sh")
    ctx
  end

  defp sh(ctx, script, env \\ []) do
    System.cmd("sh", [Path.join(ctx.etc, script)],
      env:
        [
          {"CREW_BOX_ETC", ctx.etc},
          {"CREW_BOX_DATA", ctx.data},
          {"CREW_BOX_UNITS", ctx.units},
          {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  @nonce "0123456789abcdef0123456789abcdef"

  # What the agent stages: the tarballs as it downloaded them, and the
  # request (CrewAgent.Updater.RootStep's format).
  defp stage(ctx, version, opts \\ []) do
    key = Keyword.get(opts, :key, ctx.key)
    files = write_release(Path.join(ctx.root, "release-#{version}"), key, version, "linux-arm64")
    stage = Path.join(ctx.data, "agent/update")
    File.mkdir_p!(stage)
    File.cp!(files["agent"].path, Path.join(stage, "agent.tar.gz"))
    File.cp!(files["cache"].path, Path.join(stage, "cache.tar.gz"))

    fields =
      [
        NONCE: @nonce,
        VERSION: version,
        TARGET: "linux-arm64",
        AGENT_SHA256: files["agent"].sha256,
        AGENT_SIG: files["agent"].signature,
        CACHE_SHA256: files["cache"].sha256,
        CACHE_SIG: files["cache"].signature
      ]
      |> Keyword.merge(Keyword.get(opts, :fields, []))

    File.write!(
      Path.join(stage, "request"),
      Enum.map_join(fields, fn {k, v} -> "#{k}=#{v}\n" end)
    )

    files
  end

  defp result(ctx), do: File.read!(Path.join(ctx.data, "root/update.result"))
  defp root_current(ctx), do: File.read_link!(Path.join(ctx.data, "root/current"))

  test "installs root's half from the staged tarballs, moves root/current and answers", ctx do
    stage(ctx, "0.4.0")
    assert {out, 0} = sh(ctx, "root-install.sh")
    assert out =~ "installed root's half of 0.4.0"

    assert result(ctx) == "ok #{@nonce} 0.4.0\n"
    assert root_current(ctx) == "0.4.0"
    # The request was taken: the path unit won't start this again.
    refute File.exists?(Path.join(ctx.data, "agent/update/request"))

    new = Path.join(ctx.data, "root/0.4.0")
    assert File.read!(Path.join(new, "bin/crew-vmctl")) =~ "crew-vmctl 0.4.0"

    for f <- ~w(bin/jailer bin/firecracker etc/nft.conf etc/connlimit.rules),
        do: assert(File.exists?(Path.join(new, f)), f)

    for unit <- vmctl_units() do
      text = File.read!(Path.join([new, "etc/systemd", unit]))
      refute text =~ "/srv/crew/agent/", unit
      # And the units are in place, reloaded.
      assert File.read!(Path.join(ctx.units, unit)) == text
    end

    assert File.read!(ctx.log) =~ "systemctl daemon-reload"
    # The release before stays for a rollback.
    assert File.dir?(Path.join(ctx.data, "root/0.3.0"))
  end

  test "refuses tarballs signed by another key, and leaves root as it was", ctx do
    stage(ctx, "0.4.0", key: Crew.ImageFixtures.keypair())
    assert {_out, 1} = sh(ctx, "root-install.sh")

    assert result(ctx) ==
             "error #{@nonce} the agent's signature doesn't verify against the release key\n"

    assert root_current(ctx) == "0.3.0"
    refute File.exists?(Path.join(ctx.data, "root/0.4.0"))
  end

  test "refuses a tarball that isn't the one the request names", ctx do
    stage(ctx, "0.4.0", fields: [CACHE_SHA256: String.duplicate("0", 64)])
    assert {_, 1} = sh(ctx, "root-install.sh")
    assert result(ctx) == "error #{@nonce} the cache doesn't match its SHA-256\n"
    assert root_current(ctx) == "0.3.0"
  end

  test "refuses a staged link, whatever it points at", ctx do
    stage(ctx, "0.4.0")
    agent = Path.join(ctx.data, "agent/update/agent.tar.gz")
    File.rm!(agent)
    File.ln_s!(Path.join(ctx.root, "release-0.4.0/crew-agent-0.4.0-linux-arm64.tar.gz"), agent)

    assert {_, 1} = sh(ctx, "root-install.sh")
    assert result(ctx) == "error #{@nonce} the agent tarball isn't staged\n"
  end

  # A rename keeps the inode: an agent that kept a hard link to what it
  # staged (or a descriptor open on it) could write other bytes in after
  # root checked the agent tarball, while root checked crew_cache's, and
  # root would install them. Root checks and unpacks only a copy of its
  # own. The overwrite comes from an openssl stand-in, during the cache's
  # signature check.
  test "bytes written into a staged tarball after it's checked aren't installed", ctx do
    stage(ctx, "0.4.0")
    staged = Path.join(ctx.data, "agent/update/agent.tar.gz")
    kept = Path.join(ctx.root, "agent-kept-link")
    File.ln!(staged, kept)

    # Same version and size, other bytes: an unsigned crew-vmctl.
    evil =
      agent_entries("0.4.0")
      |> Enum.map(fn
        {"bin/crew-vmctl", _} -> {"bin/crew-vmctl", "#!/bin/sh\necho EVIL crew-vmctl\n"}
        entry -> entry
      end)
      |> tarball()

    File.write!(Path.join(ctx.root, "evil.tar.gz"), evil)
    openssl = System.find_executable("openssl")

    File.write!(Path.join(ctx.bin, "openssl"), """
    #!/bin/sh
    case "$*" in
      *cache.sig*) cat "#{Path.join(ctx.root, "evil.tar.gz")}" > "#{kept}" ;;
    esac
    exec "#{openssl}" "$@"
    """)

    File.chmod!(Path.join(ctx.bin, "openssl"), 0o755)

    assert {out, 0} = sh(ctx, "root-install.sh")
    # The overwrite did happen, to the inode the agent kept...
    assert File.read!(kept) == evil, out
    # ...and root installed the bytes it checked.
    assert result(ctx) == "ok #{@nonce} 0.4.0\n"
    assert File.read!(Path.join(ctx.data, "root/0.4.0/bin/crew-vmctl")) =~ "crew-vmctl 0.4.0"
    refute File.read!(Path.join(ctx.data, "root/0.4.0/bin/crew-vmctl")) =~ "EVIL"
  end

  for {field, value} <- [
        VERSION: "../../etc",
        TARGET: "linux-amd64",
        AGENT_SHA256: "$(reboot)",
        AGENT_SIG: "a b"
      ] do
    test "refuses a request with a bad #{field}", ctx do
      stage(ctx, "0.4.0", fields: [{unquote(field), unquote(value)}])
      assert {_, 1} = sh(ctx, "root-install.sh")
      assert result(ctx) =~ ~r/\Aerror #{@nonce} the request/
      assert root_current(ctx) == "0.3.0"
    end
  end

  test "without a nonce there's no one to answer, and nothing is done", ctx do
    stage(ctx, "0.4.0", fields: [NONCE: "nope"])
    assert {_, 1} = sh(ctx, "root-install.sh")
    refute File.exists?(Path.join(ctx.data, "root/update.result"))
    refute File.exists?(Path.join(ctx.data, "agent/update/request"))
    assert root_current(ctx) == "0.3.0"
  end

  test "without a request does nothing", ctx do
    assert {_, 0} = sh(ctx, "root-install.sh")
    assert root_current(ctx) == "0.3.0"
  end

  test "reloads the packet filter itself when the ruleset changed, not through crew-net", ctx do
    nft = Path.join(ctx.data, "root/0.3.0/etc/nft.conf")
    File.chmod!(nft, 0o644)
    File.write!(nft, "table inet crew { }\n# older\n")

    stage(ctx, "0.4.0")
    assert {out, 0} = sh(ctx, "root-install.sh")
    # The stand-in crew-vmctl says which release ran.
    assert out =~ "crew-vmctl 0.4.0"
    refute File.read!(ctx.log) =~ ~r/restart crew-net/
  end

  describe "the rollback unit (crew-agent-rollback.service)" do
    setup ctx do
      stage(ctx, "0.4.0")
      assert {_, 0} = sh(ctx, "root-install.sh")
      # What the agent does once root answers.
      agent = Path.join(ctx.data, "agent")
      File.cp_r!(Path.join(agent, "0.3.0"), Path.join(agent, "0.4.0"))
      File.ln_s!("0.3.0", Path.join(agent, "previous"))
      File.rm!(Path.join(agent, "current"))
      File.ln_s!("0.4.0", Path.join(agent, "current"))
      File.write!(Path.join(agent, "update-pending"), ~s({"version":"0.4.0","op_id":"x"}))
      File.write!(ctx.log, "")
      %{agent: agent}
    end

    test "moves the agent and root's half back, and leaves the marker for the agent to report",
         ctx do
      assert {out, 0} = sh(ctx, "agent-rollback.sh")
      assert out =~ "rolled the agent back to 0.3.0"

      assert File.read_link!(Path.join(ctx.agent, "current")) == "0.3.0"
      refute File.exists?(Path.join(ctx.agent, "previous"))
      refute File.exists?(Path.join(ctx.agent, "update-pending"))
      assert File.read!(Path.join(ctx.agent, "rolled-back")) =~ ~s("version":"0.4.0")
      assert root_current(ctx) == "0.3.0"

      log = File.read!(ctx.log)
      assert log =~ "systemctl restart crew-cache.service"
      assert log =~ "systemctl start crew-agent.service"
    end

    test "with nothing to go back to, does nothing", ctx do
      File.rm!(Path.join(ctx.agent, "previous"))
      assert {out, 0} = sh(ctx, "agent-rollback.sh")
      assert out =~ "no previous release"
      assert File.read_link!(Path.join(ctx.agent, "current")) == "0.4.0"
    end

    # A compromised agent writes `previous`, and exits 75 to have root
    # roll back: root must never follow it out of root/. One good line
    # in a multi-line value used to pass the version check, and root
    # pointed root/current at the agent's directory and started its units.
    test "a previous that climbs out of root/ is refused, whatever else it holds", ctx do
      payload = Path.join(ctx.agent, "payload\n1.2.3")
      File.mkdir_p!(Path.join(payload, "etc/systemd"))

      for unit <- vmctl_units(),
          do:
            File.write!(
              Path.join([payload, "etc/systemd", unit]),
              "[Service]\nExecStart=/bin/evil\n"
            )

      File.rm!(Path.join(ctx.agent, "previous"))
      File.ln_s!("../agent/payload\n1.2.3", Path.join(ctx.agent, "previous"))

      assert {out, 1} = sh(ctx, "agent-rollback.sh")
      assert out =~ "isn't a release"
      assert root_current(ctx) == "0.4.0"
      assert File.read_link!(Path.join(ctx.agent, "current")) == "0.4.0"
      refute File.read!(ctx.log) =~ "start crew-agent"

      for unit <- vmctl_units(),
          do: refute(File.read!(Path.join(ctx.units, unit)) =~ "/bin/evil", unit)
    end

    for {label, value} <- [
          {"two lines", "0.3.0\n0.3.0"},
          {"a dot-dot", ".."},
          {"a slash", "0.3.0/../0.3.0"},
          {"a trailing newline", "0.3.0\n"}
        ] do
      test "a previous with #{label} is refused", ctx do
        File.rm!(Path.join(ctx.agent, "previous"))
        File.ln_s!(unquote(value), Path.join(ctx.agent, "previous"))
        assert {out, 1} = sh(ctx, "agent-rollback.sh")
        assert out =~ "isn't a release"
        assert root_current(ctx) == "0.4.0"
      end
    end

    # Only a release root installed itself: a directory, root's (here,
    # the test's user's), and not a link, wherever it points.
    test "root's half goes back only to a real root/<version> directory", ctx do
      root = Path.join(ctx.data, "root")
      File.rm_rf!(Path.join(root, "0.3.0"))
      File.ln_s!(Path.join(ctx.agent, "0.4.0"), Path.join(root, "0.3.0"))

      assert {out, 0} = sh(ctx, "agent-rollback.sh")
      assert out =~ "rolled the agent back to 0.3.0"
      assert out =~ "root has no 0.3.0 of its own"
      assert root_current(ctx) == "0.4.0"
    end
  end

  test "release_version takes one line holding a version, and nothing else", ctx do
    check = fn value ->
      {_, status} =
        System.cmd("sh", ["-c", ~s(. "$1/lib.sh"; release_version "$2"), "sh", ctx.etc, value])

      status == 0
    end

    assert check.("0.3.0")
    assert check.("1.2.3-rc.1")

    for bad <- [
          "",
          "..",
          ".",
          "0.3.0\n",
          "x\n0.3.0",
          "0.3.0\nx",
          "../x\n1.2.3",
          "1.2.3/..",
          "01.2"
        ] do
      refute check.(bad), inspect(bad)
    end
  end

  test "a request that's a link is no request: root never reads through it", ctx do
    stage(ctx, "0.4.0")
    secret = Path.join(ctx.root, "root-only")
    File.write!(secret, "NONCE=#{String.duplicate("0", 32)}\nVERSION=9.9.9\n")
    request = Path.join(ctx.data, "agent/update/request")
    File.rm!(request)
    File.ln_s!(secret, request)

    assert {out, 0} = sh(ctx, "root-install.sh")
    assert out =~ "no request"
    refute File.exists?(Path.join(ctx.data, "root/update.result"))
    assert root_current(ctx) == "0.3.0"
  end
end
