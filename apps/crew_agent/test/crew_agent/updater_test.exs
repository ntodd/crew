defmodule CrewAgent.UpdaterTest do
  @moduledoc """
  `agent.update` on the agent (§20.2): a local HTTP server serves signed
  release tarballs made for the test, and the agent installs them beside
  its current release in a data directory of the test's own.
  """
  use ExUnit.Case, async: true

  alias CrewAgent.{Config, Updater}
  alias CrewProtocol.Auth

  defmodule Files do
    @moduledoc false
    # Serves `/<name>` from what the test registered in an Agent, and
    # tells the test about each request.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{agent: agent, test: test}) do
      name = String.trim_leading(conn.request_path, "/")
      send(test, {:request, name})

      case Agent.get(agent, & &1[name]) do
        nil -> send_resp(conn, 404, "not found")
        body -> send_resp(conn, 200, body)
      end
    end
  end

  @darwin "darwin-arm64"
  @linux "linux-arm64"
  @units ~w(crew-net-site4.service crew-net-site4.timer crew-net.service crew-vmctl.socket crew-vmctl@.service)

  setup do
    data = Path.join(System.tmp_dir!(), "crew-updater-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data) end)
    agent_dir = Path.join(data, "agent")
    File.mkdir_p!(agent_dir)

    # What's running now: 0.1.0, installed as the first install leaves it.
    File.mkdir_p!(Path.join(agent_dir, "0.1.0/bin"))
    File.write!(Path.join(agent_dir, "0.1.0/bin/crew_agent"), "old")
    File.ln_s!("0.1.0", Path.join(agent_dir, "current"))

    files = start_supervised!({Agent, fn -> %{} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Files, %{agent: files, test: self()}},
         scheme: :http,
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {public, private} = Auth.generate_keypair()

    %{
      config: %Config{driver: "null", data_dir: data, release_public_key: public},
      agent_dir: agent_dir,
      private: private,
      files: files,
      base: "http://127.0.0.1:#{port}"
    }
  end

  # -- fixtures ------------------------------------------------------------------

  defp tarball(entries) do
    path = Path.join(System.tmp_dir!(), "crew-tar-#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        for({name, body} <- entries, do: {String.to_charlist(name), body}),
        [:compressed]
      )

    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp agent_entries(@darwin, version) do
    [
      {"bin/crew_agent", "#!/bin/sh\necho crew_agent #{version}\n"},
      {"bin/crew-launch", "#!/bin/sh\n"},
      {"bin/crew-vz", "crew-vz #{version}"},
      {"share/sandbox.sb", "(version 1)\n"},
      {"releases/#{version}/start_erl.data", "x"}
    ]
  end

  defp agent_entries(@linux, version) do
    [
      {"bin/crew_agent", "#!/bin/sh\necho crew_agent #{version}\n"},
      {"bin/crew-vmctl", "crew-vmctl"},
      {"bin/jailer", "jailer"},
      {"bin/firecracker", "firecracker"},
      {"etc/nft.conf", "table inet crew {}\n"},
      {"etc/connlimit.rules", "*mangle\nCOMMIT\n"}
    ] ++ for(unit <- @units, do: {"etc/systemd/#{unit}", "[Unit]\n"})
  end

  # Serves a signed tarball of `entries` as `name`; returns its ref.
  defp serve(ctx, name, version, target, bytes, opts \\ []) do
    Agent.update(ctx.files, &Map.put(&1, name, Keyword.get(opts, :served, bytes)))
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    key = Keyword.get(opts, :key, ctx.private)

    %{
      url: "#{ctx.base}/#{name}",
      sha256: sha,
      size: byte_size(bytes),
      signature: Auth.sign_release(version, Keyword.get(opts, :signed_for, target), sha, key)
    }
  end

  defp payload(ctx, version, target, opts \\ []) do
    bytes = Keyword.get_lazy(opts, :bytes, fn -> tarball(agent_entries(target, version)) end)
    agent = serve(ctx, "crew-agent-#{version}-#{target}.tar.gz", version, target, bytes, opts)

    cache =
      if String.starts_with?(target, "linux") and not Keyword.get(opts, :no_cache, false) do
        bytes = tarball([{"bin/crew_cache", "crew_cache #{version}"}])
        serve(ctx, "crew-cache-#{version}-#{target}.tar.gz", version, target, bytes)
      end

    Map.merge(agent, %{version: version})
    |> then(&if(cache, do: Map.put(&1, :cache, cache), else: &1))
  end

  defp run(ctx, payload, opts \\ []) do
    defaults = [
      op_id: "0190f0a2-0000-7000-8000-00000000b001",
      running: "0.1.0",
      target: @darwin,
      busy?: fn -> false end,
      starting?: fn -> false end,
      poll_ms: 5,
      download: [retry_delay_ms: 1, attempts: 2]
    ]

    Updater.run(payload, ctx.config, Keyword.merge(defaults, opts))
  end

  defp link(ctx, name) do
    case File.read_link(Path.join(ctx.agent_dir, name)) do
      {:ok, target} -> target
      {:error, _} -> nil
    end
  end

  defp marker(ctx),
    do: ctx.agent_dir |> Path.join("update-pending") |> File.read!() |> JSON.decode!()

  # -- installing ----------------------------------------------------------------

  describe "an update that installs" do
    test "unpacks beside the current release, then swaps current and previous with a marker",
         ctx do
      payload = payload(ctx, "0.2.0", @darwin)

      assert {:ok, %{"version" => "0.2.0", "restart" => true, "from" => "0.1.0"}} =
               run(ctx, payload)

      assert link(ctx, "current") == "0.2.0"
      assert link(ctx, "previous") == "0.1.0"
      assert File.read!(Path.join(ctx.agent_dir, "0.2.0/bin/crew_agent")) =~ "crew_agent 0.2.0"
      # The release it replaced is kept for a rollback.
      assert File.read!(Path.join(ctx.agent_dir, "0.1.0/bin/crew_agent")) == "old"

      assert %{
               "op_id" => "0190f0a2-0000-7000-8000-00000000b001",
               "version" => "0.2.0",
               "from" => "0.1.0",
               "installed_at" => at
             } = marker(ctx)

      assert_in_delta at, System.os_time(:second), 5

      # Nothing else of the update is left behind, and nobody else can
      # write the new release.
      assert ctx.agent_dir |> File.ls!() |> Enum.sort() ==
               ["0.1.0", "0.2.0", "current", "previous", "update-pending"]

      for file <- ["bin", "bin/crew_agent", "share/sandbox.sb"] do
        mode = File.stat!(Path.join(ctx.agent_dir, "0.2.0/" <> file)).mode
        assert Bitwise.band(mode, 0o022) == 0, file
      end
    end

    test "on Linux, puts crew_cache in the release and hands the root half to root", ctx do
      payload = payload(ctx, "0.2.0", @linux)
      test = self()

      root_step = fn staged ->
        sha = File.read!(staged.agent.path) |> then(&:crypto.hash(:sha256, &1))
        current = File.read_link(Path.join(ctx.agent_dir, "current"))
        send(test, {:root_step, staged, current, Base.encode16(sha, case: :lower)})
        :ok
      end

      after_swap = fn -> send(test, {:after_swap, link(ctx, "current")}) end

      assert {:ok, %{"version" => "0.2.0", "restart" => true}} =
               run(ctx, payload, target: @linux, root_step: root_step, after_swap: after_swap)

      assert File.read!(Path.join(ctx.agent_dir, "0.2.0/cache/bin/crew_cache")) ==
               "crew_cache 0.2.0"

      # Root gets the tarballs themselves, with what they're signed with,
      # before the agent's current moves: root checks them again itself.
      assert_received {:root_step, staged, {:ok, "0.1.0"}, staged_sha}
      assert staged.version == "0.2.0"
      assert staged.target == @linux
      assert staged.agent.sha256 == payload.sha256
      assert staged.agent.signature == payload.signature
      assert staged.cache.sha256 == payload.cache.sha256
      assert staged_sha == payload.sha256
      # The staged downloads go once root has them.
      refute File.exists?(Path.join(ctx.agent_dir, "update"))

      # crew-cache restarts onto the new release once current points at it.
      assert_received {:after_swap, "0.2.0"}
    end

    test "a Linux update without crew_cache is refused", ctx do
      payload = payload(ctx, "0.2.0", @linux, no_cache: true)
      assert {:error, "no_cache", message} = run(ctx, payload, target: @linux)
      assert message =~ "crew_cache"
      refute_received {:request, _}
      assert link(ctx, "current") == "0.1.0"
    end

    test "a root half root refuses leaves the agent where it was", ctx do
      payload = payload(ctx, "0.2.0", @linux)

      assert {:error, "root_install_failed", message} =
               run(ctx, payload,
                 target: @linux,
                 root_step: fn _ -> {:error, "the agent's signature doesn't verify"} end
               )

      assert message =~ "the agent's signature doesn't verify"
      assert link(ctx, "current") == "0.1.0"
      refute link(ctx, "previous")
      refute File.exists?(Path.join(ctx.agent_dir, "0.2.0"))
      refute File.exists?(Path.join(ctx.agent_dir, "update-pending"))
    end

    test "an update over one that hasn't joined yet keeps the release that did", ctx do
      assert {:ok, _} = run(ctx, payload(ctx, "0.2.0", @darwin))
      # 0.2.0 hasn't joined when 0.3.0 comes (the old release is still
      # waiting to restart): 0.1.0 is still the one to go back to.
      assert {:ok, %{"from" => "0.1.0"}} = run(ctx, payload(ctx, "0.3.0", @darwin))
      assert link(ctx, "current") == "0.3.0"
      assert link(ctx, "previous") == "0.1.0"
      assert marker(ctx)["version"] == "0.3.0"
    end

    test "the version already running needs nothing", ctx do
      payload = payload(ctx, "0.1.0", @darwin)
      assert {:ok, %{"version" => "0.1.0", "restart" => false}} = run(ctx, payload)
      refute_received {:request, _}
      assert link(ctx, "current") == "0.1.0"
    end

    test "the running version, asked for after an update moved current, takes current back",
         ctx do
      assert {:ok, _} = run(ctx, payload(ctx, "0.2.0", @darwin))
      assert {:ok, %{"restart" => false}} = run(ctx, payload(ctx, "0.1.0", @darwin))
      assert link(ctx, "current") == "0.1.0"
      refute link(ctx, "previous")
      refute File.exists?(Path.join(ctx.agent_dir, "update-pending"))
    end

    test "a version current already points at only needs the restart", ctx do
      assert {:ok, _} = run(ctx, payload(ctx, "0.2.0", @darwin))
      flush_requests()

      assert {:ok, %{"version" => "0.2.0", "restart" => true}} =
               run(ctx, payload(ctx, "0.2.0", @darwin))

      refute_received {:request, _}
    end
  end

  # -- refusals ------------------------------------------------------------------

  describe "an update that's refused" do
    test "without a release key, before anything is downloaded", ctx do
      ctx = put_in(ctx.config.release_public_key, nil)
      assert {:error, "no_release_key", message} = run(ctx, payload(ctx, "0.2.0", @darwin))
      assert message =~ "CREW_RELEASE_PUBLIC_KEY"
      refute_received {:request, _}
      assert link(ctx, "current") == "0.1.0"
    end

    test "signed by another key, before anything is downloaded", ctx do
      {_, other} = Auth.generate_keypair()
      payload = payload(ctx, "0.2.0", @darwin, key: other)
      assert {:error, "bad_signature", message} = run(ctx, payload)
      assert message =~ "0.2.0"
      refute_received {:request, _}
    end

    test "signed for another target", ctx do
      payload = payload(ctx, "0.2.0", @darwin, signed_for: "linux-arm64")
      assert {:error, "bad_signature", _} = run(ctx, payload)
      refute_received {:request, _}
    end

    test "a crew_cache signature that doesn't verify", ctx do
      payload = payload(ctx, "0.2.0", @linux)
      payload = put_in(payload.cache.signature, payload.signature)
      assert {:error, "bad_signature", message} = run(ctx, payload, target: @linux)
      assert message =~ "crew_cache"
      refute_received {:request, _}
    end

    test "a download that isn't the signed tarball", ctx do
      good = tarball(agent_entries(@darwin, "0.2.0"))
      evil = tarball(agent_entries(@darwin, "evil"))
      # The same size, other bytes.
      evil = binary_part(evil <> :binary.copy(<<0>>, byte_size(good)), 0, byte_size(good))
      payload = payload(ctx, "0.2.0", @darwin, bytes: good, served: evil)

      assert {:error, "sha256_mismatch", _} = run(ctx, payload)
      assert link(ctx, "current") == "0.1.0"
      refute File.exists?(Path.join(ctx.agent_dir, "0.2.0"))
      assert ctx.agent_dir |> File.ls!() |> Enum.sort() == ["0.1.0", "current"]
    end

    test "a download longer than its size", ctx do
      good = tarball(agent_entries(@darwin, "0.2.0"))
      payload = payload(ctx, "0.2.0", @darwin, bytes: good, served: good <> "more")
      assert {:error, "download_failed", message} = run(ctx, payload)
      assert message =~ "more than the expected"
      assert link(ctx, "current") == "0.1.0"
    end

    for {label, name} <- [
          {"climbs out of the release", "../../escaped"},
          {"is absolute", "/tmp/crew-updater-absolute"},
          {"climbs out from inside", "bin/../../escaped"}
        ] do
      test "a tarball with a path that #{label}", ctx do
        bytes = tarball(agent_entries(@darwin, "0.2.0") ++ [{unquote(name), "x"}])
        payload = payload(ctx, "0.2.0", @darwin, bytes: bytes)

        assert {:error, "bad_release", message} = run(ctx, payload)
        assert message =~ "unsafe path"
        refute File.exists?(Path.join(ctx.config.data_dir, "escaped"))
        refute File.exists?("/tmp/crew-updater-absolute")
        refute File.exists?(Path.join(ctx.agent_dir, "0.2.0"))
        assert link(ctx, "current") == "0.1.0"
      end
    end

    test "a tarball with a link in it", ctx do
      dir = Path.join(System.tmp_dir!(), "crew-link-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      File.ln_s!("/etc", Path.join(dir, "etc"))
      tar = Path.join(dir, "t.tar.gz")

      entries =
        for(
          {name, body} <- agent_entries(@darwin, "0.2.0"),
          do: {String.to_charlist(name), body}
        ) ++
          [{~c"etc", String.to_charlist(Path.join(dir, "etc"))}]

      :ok = :erl_tar.create(String.to_charlist(tar), entries, [:compressed])
      payload = payload(ctx, "0.2.0", @darwin, bytes: File.read!(tar))

      assert {:error, "bad_release", message} = run(ctx, payload)
      assert message =~ "etc"
      assert link(ctx, "current") == "0.1.0"
    end

    test "a release missing what this box runs", ctx do
      entries = Enum.reject(agent_entries(@darwin, "0.2.0"), &(elem(&1, 0) == "bin/crew-launch"))
      payload = payload(ctx, "0.2.0", @darwin, bytes: tarball(entries))

      assert {:error, "bad_release", message} = run(ctx, payload)
      assert message =~ "bin/crew-launch"
      assert link(ctx, "current") == "0.1.0"
    end
  end

  # -- waiting -------------------------------------------------------------------

  describe "waiting before the swap" do
    test "waits for in-flight operations, then for no VM to be starting", ctx do
      test = self()
      {:ok, busy} = Agent.start_link(fn -> 3 end)
      {:ok, starting} = Agent.start_link(fn -> 2 end)

      countdown = fn agent, what ->
        fn ->
          left = Agent.get_and_update(agent, &{&1, max(&1 - 1, 0)})
          send(test, {what, left, link(ctx, "current")})
          left > 0
        end
      end

      assert {:ok, _} =
               run(ctx, payload(ctx, "0.2.0", @darwin),
                 busy?: countdown.(busy, :busy),
                 starting?: countdown.(starting, :starting)
               )

      # The release is unpacked first, and current moves only once both
      # waits are over.
      assert_received {:busy, 3, "0.1.0"}
      assert_received {:busy, 0, "0.1.0"}
      assert_received {:starting, 2, "0.1.0"}
      assert_received {:starting, 0, "0.1.0"}
      assert File.exists?(Path.join(ctx.agent_dir, "0.2.0/bin/crew_agent"))
      assert link(ctx, "current") == "0.2.0"
    end

    test "goes ahead once the waits run out", ctx do
      assert {:ok, %{"version" => "0.2.0"}} =
               run(ctx, payload(ctx, "0.2.0", @darwin),
                 busy?: fn -> true end,
                 starting?: fn -> true end,
                 ops_wait_ms: 20,
                 starting_wait_ms: 20
               )

      assert link(ctx, "current") == "0.2.0"
    end

    test "the bounds are §20.2's" do
      assert Updater.ops_wait_ms() == 10 * 60_000
      assert Updater.starting_wait_ms() == 90_000
    end
  end

  # -- after the restart ---------------------------------------------------------

  describe "the new release" do
    setup ctx do
      {:ok, _} = run(ctx, payload(ctx, "0.2.0", @darwin))
      :ok
    end

    test "that joins keeps itself and drops the rollback state", ctx do
      File.mkdir_p!(Path.join(ctx.agent_dir, "0.0.9/bin"))
      File.write!(Path.join(ctx.agent_dir, "crashes"), "1\n2\n")

      assert :confirmed = Updater.confirm(ctx.config, running: "0.2.0")
      assert link(ctx, "current") == "0.2.0"
      refute link(ctx, "previous")
      refute File.exists?(Path.join(ctx.agent_dir, "update-pending"))
      refute File.exists?(Path.join(ctx.agent_dir, "crashes"))
      # Releases nothing points at are pruned; the running one stays.
      assert ctx.agent_dir |> File.ls!() |> Enum.sort() == ["0.2.0", "current"]
    end

    test "the old release, still waiting to restart, leaves it alone", ctx do
      assert :ok = Updater.confirm(ctx.config, running: "0.1.0")
      assert link(ctx, "previous") == "0.1.0"
      assert File.exists?(Path.join(ctx.agent_dir, "update-pending"))
    end

    # The clock is the test's: `now` and the boot id are given.
    defp start(ctx, now, opts \\ []) do
      Updater.on_start(
        Keyword.get(opts, :config, ctx.config),
        Keyword.merge([running: "0.2.0", boot_id: "boot-1", now: now], opts)
      )
    end

    defp due?(ctx, now, opts \\ []),
      do:
        Updater.rollback_due?(
          ctx.config,
          now,
          Keyword.merge([running: "0.2.0", boot_id: "boot-1"], opts)
        )

    test "the first start this boot is kept in the marker, however many follow", ctx do
      t0 = 1_800_000_000
      refute due?(ctx, t0 + 10_000)

      assert :ok = start(ctx, t0)
      assert %{"first_start_at" => ^t0, "boot_id" => "boot-1"} = marker(ctx)
      assert :ok = start(ctx, t0 + 90)
      assert :ok = start(ctx, t0 + 180)
      assert marker(ctx)["first_start_at"] == t0

      refute due?(ctx, t0 + 299)
      assert due?(ctx, t0 + 300)
    end

    # A release that dies every 90 s never trips the service manager's
    # crash-loop limits, and restarted the old 5 minutes with each process.
    test "a release that keeps dying slowly is rolled back 5 minutes after its first start",
         ctx do
      t0 = 1_800_000_000

      for n <- 0..3, do: assert(:ok = start(ctx, t0 + n * 90))

      assert {:stop, 1} = start(ctx, t0 + 4 * 90)
      assert link(ctx, "current") == "0.1.0"

      assert {:rolled_back, %{reason: reason}} = Updater.confirm(ctx.config, running: "0.1.0")
      assert reason =~ "5 minutes"
    end

    test "on Firecracker the rollback at start is left to root's rollback unit", ctx do
      t0 = 1_800_000_000
      fc = %{ctx.config | driver: "firecracker"}
      assert :ok = start(ctx, t0, config: fc)
      assert {:stop, 75} = start(ctx, t0 + 301, config: fc)
      assert link(ctx, "current") == "0.2.0"
    end

    test "a host reboot gives the release its 5 minutes again", ctx do
      t0 = 1_800_000_000
      assert :ok = start(ctx, t0)
      assert :ok = start(ctx, t0 + 3600, boot_id: "boot-2")
      assert marker(ctx)["first_start_at"] == t0 + 3600
      refute due?(ctx, t0 + 3600 + 299, boot_id: "boot-2")
      assert due?(ctx, t0 + 3600 + 300, boot_id: "boot-2")
      # A start from the boot before doesn't count on this one.
      refute due?(ctx, t0 + 9999, boot_id: "boot-3")
    end

    test "only the release current points at is timed", ctx do
      t0 = 1_800_000_000
      # The old release, still waiting to restart into the new one.
      assert :ok = start(ctx, t0, running: "0.1.0")
      refute Map.has_key?(marker(ctx), "first_start_at")
      assert :ok = start(ctx, t0)
      refute due?(ctx, t0 + 999, running: "0.1.0")
    end

    test "a rollback goes back to previous and leaves a note for the release it lands on", ctx do
      assert :ok = Updater.rollback(ctx.config, "it didn't join within 5 minutes")
      assert link(ctx, "current") == "0.1.0"
      refute link(ctx, "previous")
      refute File.exists?(Path.join(ctx.agent_dir, "update-pending"))
      refute Updater.rollback_due?(ctx.config, System.os_time(:second) + 999, running: "0.1.0")

      # 0.1.0, joining, reports the update as failed (§20.2's two failures).
      assert {:rolled_back,
              %{
                op_id: "0190f0a2-0000-7000-8000-00000000b001",
                version: "0.2.0",
                reason: "it didn't join within 5 minutes"
              }} = Updater.confirm(ctx.config, running: "0.1.0")

      refute File.exists?(Path.join(ctx.agent_dir, "rolled-back"))
      assert :ok = Updater.confirm(ctx.config, running: "0.1.0")
    end

    test "the watchdog rolls back on macOS, and leaves it to root's rollback unit on Linux",
         ctx do
      t0 = 1_800_000_000
      assert :ok = start(ctx, t0)
      opts = [running: "0.2.0", boot_id: "boot-1"]

      assert :ok = Updater.watchdog(ctx.config, t0 + 10, opts)
      assert link(ctx, "current") == "0.2.0"

      # Firecracker: root's half moves too, so crew-agent-rollback.service
      # does it, started by an exit systemd doesn't restart.
      fc = %{ctx.config | driver: "firecracker"}
      assert {:stop, 75} = Updater.watchdog(fc, t0 + 301, opts)
      assert link(ctx, "current") == "0.2.0"
      assert Updater.rollback_exit_status() == 75

      # Elsewhere the agent switches back itself and exits to be restarted.
      assert {:stop, 1} = Updater.watchdog(ctx.config, t0 + 301, opts)
      assert link(ctx, "current") == "0.1.0"

      assert {:rolled_back, %{reason: reason}} = Updater.confirm(ctx.config, running: "0.1.0")
      assert reason =~ "didn't join"
    end

    test "a rollback only goes back to a release's name, never a path", ctx do
      for bad <- ["../elsewhere", "0.1.0\n", "..", "0.1.0/../x"] do
        File.rm!(Path.join(ctx.agent_dir, "previous"))
        File.ln_s!(bad, Path.join(ctx.agent_dir, "previous"))
        assert {:error, :no_previous} = Updater.rollback(ctx.config, "test"), inspect(bad)
        assert link(ctx, "current") == "0.2.0"
      end
    end

    test "a rollback by the service manager (crew-launch, agent-rollback.sh) is reported too",
         ctx do
      # They only rename the marker: the release they land on reports it.
      File.rename!(
        Path.join(ctx.agent_dir, "update-pending"),
        Path.join(ctx.agent_dir, "rolled-back")
      )

      File.rm!(Path.join(ctx.agent_dir, "current"))
      File.ln_s!("0.1.0", Path.join(ctx.agent_dir, "current"))

      assert {:rolled_back, %{version: "0.2.0", reason: reason}} =
               Updater.confirm(ctx.config, running: "0.1.0")

      assert reason =~ "crash"
    end
  end

  test "agent.update reaches the updater (the test agent has no release key)" do
    {:ok, cmd} =
      CrewProtocol.Command.new("agent.update", CrewProtocol.Examples.command("agent.update"))

    assert {:error, "no_release_key", _} = CrewAgent.Handler.handle(cmd)
  end

  test "the release target is this build's" do
    assert Updater.target() =~ ~r/\A(linux|darwin)-(amd64|arm64)\z/
  end

  defp flush_requests do
    receive do
      {:request, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
