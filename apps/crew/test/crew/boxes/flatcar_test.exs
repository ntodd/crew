defmodule Crew.Boxes.FlatcarTest do
  @moduledoc """
  The Ignition for a Flatcar box (§12.1, §12.2, §12.4, §10.8): every unit
  and file of §12.2's table, the settings of §12.1, the data disk and its
  quotas, and the secrets kept to root.
  """
  use ExUnit.Case, async: true

  alias Crew.Boxes.Flatcar

  @release_key :binary.copy(<<7>>, 32)
  @sha_agent String.duplicate("a", 64)
  @sha_cache String.duplicate("c", 64)

  @opts %{
    mode: :provision,
    name: "m3max",
    type: "linux-vm",
    arch: "arm64",
    url: "https://crew.tail1234.ts.net",
    join_token: "cj_secret-join-token",
    tailscale_auth_key: "tskey-auth-secret-key",
    ssh_keys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore crew-box@host"],
    release_key: @release_key,
    release: %{
      version: "0.3.0",
      agent: %{
        url: "https://example.test/crew-agent-0.3.0-linux-arm64.tar.gz",
        sha256: @sha_agent,
        signature: "c2lnLWFnZW50"
      },
      cache: %{
        url: "https://example.test/crew-cache-0.3.0-linux-arm64.tar.gz",
        sha256: @sha_cache,
        signature: "c2lnLWNhY2hl"
      }
    },
    dev: false
  }

  defp ignition(overrides \\ %{}) do
    assert {:ok, config} = Flatcar.ignition(Map.merge(@opts, Map.new(overrides)))
    # What goes on the wire.
    config |> Jason.encode!() |> Jason.decode!()
  end

  defp reprovision(overrides \\ %{}) do
    ignition(
      Map.merge(
        %{mode: :reprovision, join_token: nil, tailscale_auth_key: nil, release: nil, url: nil},
        Map.new(overrides)
      )
    )
  end

  defp files(config), do: config["storage"]["files"]
  defp file?(config, path), do: Enum.any?(files(config), &(&1["path"] == path))

  defp file(config, path) do
    Enum.find(files(config), &(&1["path"] == path)) ||
      flunk("no #{path} in #{inspect(Enum.map(files(config), & &1["path"]))}")
  end

  defp contents(config, path), do: decode(file(config, path))

  defp decode(%{"contents" => %{"source" => "data:;base64," <> data}}), do: Base.decode64!(data)
  defp decode(_), do: nil

  defp units(config), do: config["systemd"]["units"]
  defp unit?(config, name), do: Enum.any?(units(config), &(&1["name"] == name))

  defp unit(config, name),
    do: Enum.find(units(config), &(&1["name"] == name)) || flunk("no unit #{name}")

  defp body(config, name), do: unit(config, name)["contents"]

  test "is Ignition 3.4 and names the box" do
    config = ignition()
    assert config["ignition"]["version"] == "3.4.0"
    assert contents(config, "/etc/hostname") == "m3max\n"
  end

  test "has every unit and file in §12.2's table" do
    config = ignition()

    for name <- ~w(srv-crew.mount crew-format-data.service
                   crew-provision.service crew-agent-install.service crew-agent.service
                   crew-agent-rollback.service crew-root-units.service
                   crew-cache.service tailscaled.service crew-clock-sync.timer
                   crew-clock-sync.service crew-flatcar-update.timer
                   crew-sysext-update.timer crew-quota.service crew-box-status.service) do
      assert unit?(config, name), "no #{name}"
    end

    # crew-net and crew-vmctl's units come with the release, which also
    # knows what crew-vmctl needs of them (native/crew-vmctl/etc/systemd).
    for name <- ~w(crew-net.service crew-vmctl.socket crew-vmctl@.service crew-net-site4.timer) do
      refute unit?(config, name), "#{name} is the release's"
    end

    for path <- ~w(/etc/systemd/network/00-crew.network /etc/crew-box/provision.env
                   /etc/crew-box/provision.sh /etc/crew-box/agent-install.sh
                   /etc/crew-box/flatcar-update-check /etc/flatcar/update.conf) do
      assert file?(config, path), "no #{path}"
    end
  end

  describe "Flatcar's settings (§12.1)" do
    test "nothing reboots the box on its own" do
      assert contents(ignition(), "/etc/flatcar/update.conf") =~ ~r/^REBOOT_STRATEGY=off$/m
    end

    test "flags an applied update every minute, through sh" do
      config = ignition()
      assert body(config, "crew-flatcar-update.timer") =~ "OnUnitActiveSec=1min"
      assert unit(config, "crew-flatcar-update.timer")["enabled"]

      assert body(config, "crew-flatcar-update.service") =~
               "ExecStart=/bin/sh /etc/crew-box/flatcar-update-check"

      check = contents(config, "/etc/crew-box/flatcar-update-check")
      assert check =~ "update_engine_client -status"
      assert check =~ "UPDATE_STATUS_UPDATED_NEED_REBOOT"
      assert check =~ "/run/reboot-required.pkgs"
      assert check =~ "flatcar-${version"
    end

    for {arch, bakery} <- [{"amd64", "x86-64"}, {"arm64", "arm64"}] do
      test "adds Tailscale for #{arch}, pinned by its digest" do
        config = ignition(arch: unquote(arch))
        pins = Flatcar.pins()
        version = pins["TAILSCALE_SYSEXT_VERSION"]
        image = "tailscale-#{version}-#{unquote(bakery)}.raw"

        assert %{"target" => target} =
                 Enum.find(
                   config["storage"]["links"],
                   &(&1["path"] == "/etc/extensions/tailscale.raw")
                 )

        assert target == "/opt/extensions/tailscale/#{image}"

        sysext = file(config, target)

        assert sysext["contents"]["source"] ==
                 "https://extensions.flatcar.org/extensions/#{image}"

        assert sysext["contents"]["verification"]["hash"] ==
                 "sha256-" <> pins["TAILSCALE_SYSEXT_SHA256_#{String.upcase(unquote(arch))}"]
      end
    end

    test "updates Tailscale daily and flags a new one" do
      config = ignition()
      assert body(config, "crew-sysext-update.timer") =~ "OnCalendar=daily"

      assert body(config, "crew-sysext-update.service") =~
               "ExecStart=/bin/sh /etc/crew-box/update-sysexts.sh"

      script = contents(config, "/etc/crew-box/update-sysexts.sh")
      assert script =~ "systemd-sysupdate -C \"$ext\" update"
      assert script =~ "/run/reboot-required"

      conf = contents(config, "/etc/sysupdate.tailscale.d/tailscale.conf")
      assert conf =~ "MatchPattern=tailscale-@v-%a.raw"
      assert conf =~ "CurrentSymlink=/etc/extensions/tailscale.raw"
    end

    test "keeps Tailscale's state on the data disk" do
      config = ignition()
      tailscaled = unit(config, "tailscaled.service")
      assert tailscaled["enabled"]
      [dropin] = tailscaled["dropins"]
      assert dropin["contents"] =~ "BindPaths=/srv/crew/tailscale:/var/lib/tailscale"
      assert dropin["contents"] =~ "RequiresMountsFor=/srv/crew"
      assert contents(config, "/etc/default/tailscaled") =~ ~r/^PORT=/m
    end

    test "masks Docker, whose iptables rules would break VM forwarding" do
      config = ignition()

      for name <- ~w(docker.socket docker.service containerd.service) do
        assert unit(config, name)["mask"] == true, name
      end
    end

    test "sets the sysctls" do
      sysctl = contents(ignition(), "/etc/sysctl.d/90-crew.conf")

      for line <- [
            "net.ipv4.ip_forward = 1",
            "net.ipv6.conf.all.forwarding = 0",
            "net.ipv6.conf.default.accept_ra = 0",
            "user.max_user_namespaces = 0",
            "vm.swappiness = 0",
            "net.netfilter.nf_conntrack_max = 262144"
          ] do
        assert sysctl =~ line
      end

      # The conntrack key only exists once the module is loaded.
      assert contents(ignition(), "/etc/modules-load.d/crew.conf") =~ "nf_conntrack"
    end
  end

  describe "the data disk (§12.2, §12.4)" do
    test "is /dev/vdb for the launchers' VMs" do
      for type <- ["linux-vm", "mac-vm"] do
        config = ignition(type: type)
        format = body(config, "crew-format-data.service")
        assert format =~ "ExecStart=/bin/sh /etc/crew-box/format-data.sh /dev/vdb"
      end
    end

    test "is the device Add box was given on bare metal" do
      config = ignition(type: "linux-metal", data_disk: "/dev/disk/by-id/nvme-Samsung_SSD_990_S7")
      format = body(config, "crew-format-data.service")
      assert format =~ "format-data.sh /dev/disk/by-id/nvme-Samsung_SSD_990_S7"
    end

    # A disk can come back under another name (/dev/sdb is /dev/sdc after
    # a reboot on bare metal). The mount is by label and owes nothing to
    # the configured device; only a box with no crew-data disk anywhere
    # needs the device, to format it.
    for {type, disk} <- [{"linux-metal", "/dev/sdb"}, {"linux-vm", "/dev/vdb"}] do
      test "the mount doesn't depend on the configured device (#{type})" do
        config = ignition(type: unquote(type), data_disk: unquote(disk))
        mount = body(config, "srv-crew.mount")
        assert mount =~ "What=/dev/disk/by-label/crew-data"
        assert mount =~ "Wants=crew-format-data.service"
        assert mount =~ "After=crew-format-data.service"
        refute mount =~ "Requires=crew-format-data.service"
        refute mount =~ unquote(disk)

        format = body(config, "crew-format-data.service")
        assert format =~ "ConditionPathExists=!/dev/disk/by-label/crew-data"
        refute format =~ "BindsTo="
        refute format =~ ".device"
        assert format =~ "ExecStart=/bin/sh /etc/crew-box/format-data.sh #{unquote(disk)}"
      end
    end

    test "bare metal needs one, and only a device path" do
      assert {:error, :bad_data_disk} = Flatcar.ignition(Map.put(@opts, :type, "linux-metal"))

      for bad <- ["/dev/sdb; reboot", "/etc/passwd", "/dev/../etc", "sdb", "/dev/sd b"] do
        assert {:error, :bad_data_disk} =
                 Flatcar.ignition(Map.merge(@opts, %{type: "linux-metal", data_disk: bad})),
               bad
      end
    end

    test "is formatted only when it's empty, before it's mounted" do
      config = ignition()
      format = body(config, "crew-format-data.service")
      assert format =~ "Before=srv-crew.mount"
      assert format =~ "Type=oneshot"

      script = contents(config, "/etc/crew-box/format-data.sh")
      assert script =~ "mkfs.xfs -q -K -L \"$label\" -m reflink=1"
      assert script =~ "blkid -p"
      assert script =~ "won't format it"
    end

    test "is mounted at /srv/crew with project quotas, by its label" do
      mount = body(ignition(), "srv-crew.mount")
      assert mount =~ "Where=/srv/crew"
      assert mount =~ "What=/dev/disk/by-label/crew-data"
      assert mount =~ "Type=xfs"
      assert mount =~ ~r/^Options=.*prjquota/m
    end

    test "gets the three areas of §12.4 as XFS project quotas" do
      config = ignition()
      assert body(config, "crew-quota.service") =~ "ExecStart=/bin/sh /etc/crew-box/quota.sh"
      script = contents(config, "/etc/crew-box/quota.sh")
      assert script =~ ~s(project 10 "$data/vms" "$data/jail")
      assert script =~ ~s(project 11 "$data/cache")
      assert script =~ ~s(project 12 "$data/agent" "$data/images")
      assert script =~ "limit -p bhard="
      assert script =~ "CREW_CACHE_MAX_GIB"
    end

    # crew-vmctl refuses a jail anyone but root can write, and root/ is
    # what root runs.
    test "keeps the data disk's top, jail/ and root/ root's" do
      script = contents(ignition(), "/etc/crew-box/quota.sh")
      assert script =~ ~s(dir 0755 root:root "$data"\n)
      assert script =~ ~s(dir 0755 root:root "$data/jail")
      assert script =~ ~s(dir 0755 root:root "$data/root")
    end
  end

  describe "the network" do
    test "leaves Crew's interfaces to Crew" do
      assert contents(ignition(), "/etc/systemd/network/00-crew.network") ==
               "[Match]\nName=crewt* crew0\n\n[Link]\nUnmanaged=yes\n"
    end

    # crew-net (crew0, the ruleset, site4) is crew-vmctl's, with its units
    # in the release; the box installs and enables them at every boot.
    test "installs the release's crew-net and crew-vmctl units, and enables them" do
      config = ignition()
      root = body(config, "crew-root-units.service")
      assert unit(config, "crew-root-units.service")["enabled"]
      assert root =~ "ExecStart=/bin/sh /etc/crew-box/root-units.sh"
      assert root =~ "ConditionPathExists=/srv/crew/root/current/etc/systemd"
      assert root =~ "Before=crew-agent.service"

      script = contents(config, "/etc/crew-box/root-units.sh")
      assert script =~ "data=${CREW_BOX_DATA:-/srv/crew}"
      assert script =~ ~s(src="$data/root/current/etc/systemd")
      assert script =~ "for name in $root_units"
      lib = contents(config, "/etc/crew-box/lib.sh")

      for unit <-
            ~w(crew-vmctl.socket crew-vmctl@.service crew-net.service crew-net-site4.service crew-net-site4.timer) do
        assert lib =~ unit
      end

      assert script =~ "systemctl enable crew-net.service crew-vmctl.socket crew-net-site4.timer"
      assert script =~ "systemctl daemon-reload"
    end

    test "loads what crew-net's ruleset needs" do
      modules = contents(ignition(), "/etc/modules-load.d/crew.conf")
      for m <- ~w(nf_conntrack nft_compat xt_connlimit), do: assert(modules =~ m)
    end

    # Flatcar points /etc/resolv.conf at the uplink's servers, and its curl
    # (c-ares) reads that file directly, so it never saw Tailscale's split
    # DNS: with Funnel on, the control plane's name resolved to its public
    # Funnel address and provisioning hung (#31). resolved's stub does the
    # split. The guests' resolver doesn't use the host's (§15.2).
    for {name, config} <- [
          provision: quote(do: ignition()),
          reprovision: quote(do: reprovision())
        ] do
      test "resolves through resolved's stub (#{name})" do
        assert %{
                 "target" => "/run/systemd/resolve/stub-resolv.conf",
                 "overwrite" => true,
                 "hard" => false
               } =
                 Enum.find(
                   unquote(config)["storage"]["links"],
                   &(&1["path"] == "/etc/resolv.conf")
                 )
      end
    end

    test "asks DHCP for an address by MAC, as the mac-vm launcher looks it up" do
      assert contents(ignition(), "/etc/systemd/network/zz-default.network.d/crew-dhcp.conf") =~
               "ClientIdentifier=mac"
    end
  end

  describe "provisioning" do
    test "joins the tailnet, waits for the control plane, installs and enrolls" do
      config = ignition()
      provision = body(config, "crew-provision.service")
      assert unit(config, "crew-provision.service")["enabled"]
      assert provision =~ "ConditionPathExists=/etc/crew-box/provision.env"
      assert provision =~ "ExecStart=/bin/sh /etc/crew-box/provision.sh"
      assert provision =~ "Type=oneshot"
      assert provision =~ "Restart=on-failure"

      script = contents(config, "/etc/crew-box/provision.sh")
      assert script =~ ~s(tailscale up --auth-key="file:$key" --advertise-tags=tag:crew-box)
      assert script =~ ~s(--hostname="crew-$CREW_BOX_NAME")
      assert script =~ ~s(rm -f "$key")
      assert script =~ "$CREW_URL/healthz"
      assert script =~ "systemctl start crew-agent-install.service"
      assert script =~ ~s(rm -f "$env" /oem/config.ign)
      assert script =~ ~s(say "enrolled")
    end

    test "prints its progress on every console" do
      lib = contents(ignition(), "/etc/crew-box/lib.sh")
      assert lib =~ "/proc/consoles"
      assert lib =~ ~s[say() { console "crew-box: $*"; }]
    end

    test "carries the control plane's URL, the join token and the name, root's alone" do
      config = ignition()
      env = contents(config, "/etc/crew-box/provision.env")
      assert env =~ ~s(CREW_URL="https://crew.tail1234.ts.net")
      assert env =~ ~s(CREW_JOIN_TOKEN="cj_secret-join-token")
      assert env =~ ~s(CREW_BOX_NAME="m3max")
      assert file(config, "/etc/crew-box/provision.env")["mode"] == 0o600

      assert contents(config, "/etc/crew-box/tailscale-authkey") == "tskey-auth-secret-key"
      assert file(config, "/etc/crew-box/tailscale-authkey")["mode"] == 0o600
    end

    test "without a Tailscale key, the box reaches the control plane as it is" do
      refute file?(ignition(tailscale_auth_key: nil), "/etc/crew-box/tailscale-authkey")
    end

    test "quotes values in the env files so nothing in them runs" do
      config = ignition(url: "https://crew.example/$(reboot)")

      assert contents(config, "/etc/crew-box/provision.env") =~
               ~S|CREW_URL="https://crew.example/\$(reboot)"|
    end
  end

  describe "the agent's install" do
    test "is a oneshot on the data disk that skips an installed agent" do
      install = body(ignition(), "crew-agent-install.service")
      assert install =~ "Type=oneshot"
      assert install =~ "RequiresMountsFor=/srv/crew"
      assert install =~ "ConditionPathExists=!/srv/crew/agent/current"
      assert install =~ "ExecStart=/bin/sh /etc/crew-box/agent-install.sh"
    end

    test "downloads the release the control plane named, checked against its digests and key" do
      config = ignition()
      release = contents(config, "/etc/crew-box/release.env")
      assert release =~ ~s(CREW_VERSION="0.3.0")
      assert release =~ ~s(CREW_TARGET="linux-arm64")

      assert release =~
               ~s(CREW_AGENT_URL="https://example.test/crew-agent-0.3.0-linux-arm64.tar.gz")

      assert release =~ ~s(CREW_AGENT_SHA256="#{@sha_agent}")
      assert release =~ ~s(CREW_AGENT_SIG="c2lnLWFnZW50")
      assert release =~ ~s(CREW_CACHE_SHA256="#{@sha_cache}")
      assert release =~ ~s(CREW_AGENT_SOCKET_URL="wss://crew.tail1234.ts.net/agent/websocket")
      assert release =~ ~s(CREW_RELEASE_PUBLIC_KEY="#{Base.encode64(@release_key)}")

      assert release =~
               ~s(CREW_RELEASE_KEY_FINGERPRINT="#{CrewProtocol.Auth.fingerprint(@release_key)}")

      refute release =~ "CREW_DEV=\"1\""

      pem = contents(config, "/etc/crew-box/release-key.pem")
      [{:SubjectPublicKeyInfo, der, _}] = :public_key.pem_decode(pem)
      assert binary_part(der, byte_size(der) - 32, 32) == @release_key

      # lib.sh's check_release, which root's update step uses too.
      assert contents(config, "/etc/crew-box/agent-install.sh") =~ "check_release"
      lib = contents(config, "/etc/crew-box/lib.sh")
      assert lib =~ "openssl pkeyutl -verify -pubin"
      assert lib =~ "printf 'crew-release-v1\\n%s\\n%s\\n%s'"
    end

    test "for amd64, the linux-amd64 target" do
      assert contents(ignition(arch: "amd64"), "/etc/crew-box/release.env") =~
               ~s(CREW_TARGET="linux-amd64")
    end

    test "in development, over ws:// with CREW_DEV" do
      release =
        contents(
          ignition(url: "http://192.168.64.1:4100", dev: true),
          "/etc/crew-box/release.env"
        )

      assert release =~ ~s(CREW_AGENT_SOCKET_URL="ws://192.168.64.1:4100/agent/websocket")
      assert release =~ ~s(CREW_DEV="1")
    end

    test "needs a release and a release key" do
      assert {:error, :no_release} = Flatcar.ignition(%{@opts | release: nil})
      assert {:error, :no_release_key} = Flatcar.ignition(%{@opts | release_key: nil})
    end
  end

  describe "the agent, the cache and crew-vmctl (§10.8)" do
    test "the agent runs as _crewagent, hardened, rolled back on a crash loop" do
      config = ignition()
      assert unit(config, "crew-agent.service")["enabled"]
      agent = body(config, "crew-agent.service")

      for line <- [
            "User=_crewagent",
            "SupplementaryGroups=crewvm",
            "NoNewPrivileges=true",
            "ProtectSystem=strict",
            # The jail's console files are the agent's to cap (crew-vmctl's README).
            "ReadWritePaths=/srv/crew/agent /srv/crew/vms /srv/crew/images /srv/crew/jail",
            "OOMScoreAdjust=-900",
            "EnvironmentFile=/srv/crew/agent/env",
            "ExecStart=/srv/crew/agent/current/bin/crew_agent start",
            "OnFailure=crew-agent-rollback.service",
            "Requires=crew-net.service",
            "After=network-online.target crew-net.service crew-vmctl.socket",
            "ConditionPathExists=/srv/crew/agent/current/bin/crew_agent"
          ] do
        assert agent =~ line, line
      end

      assert body(config, "crew-agent-rollback.service") =~
               "ExecStart=/bin/sh /etc/crew-box/agent-rollback.sh"
    end

    # §20.2: a release that hasn't joined within 5 minutes exits 75, and
    # systemd fails it rather than restarting it, so the rollback unit
    # moves root's half back too.
    test "the agent's exit for a rollback isn't restarted" do
      assert body(ignition(), "crew-agent.service") =~ "RestartPreventExitStatus=75"
    end

    # §10.8, §20.2: an update's root half is installed by root, from the
    # tarballs the agent stages, checked against root's copy of the key.
    test "root installs an update's root half when the agent stages one" do
      for config <- [ignition(), reprovision()] do
        path = unit(config, "crew-root-install.path")
        assert path["enabled"]
        assert path["contents"] =~ "PathExists=/srv/crew/agent/update/request"
        assert path["contents"] =~ "Unit=crew-root-install.service"
        assert path["contents"] =~ "RequiresMountsFor=/srv/crew"

        service = body(config, "crew-root-install.service")
        assert service =~ "ExecStart=/bin/sh /etc/crew-box/root-install.sh"
        assert service =~ "Type=oneshot"
        refute service =~ ~r/^User=/m

        assert contents(config, "/etc/crew-box/root-install.sh") =~ "check_release"
        # Root's copy of the release key, in both: a reprovisioned box
        # still updates.
        assert contents(config, "/etc/crew-box/release-key.pem") =~ "BEGIN PUBLIC KEY"
        assert file(config, "/etc/crew-box/release-key.pem")["mode"] == 0o644
      end
    end

    # The agent can write agent/ (it updates itself, §20.2), so nothing
    # root runs may come from there.
    test "no root unit runs anything from the agent's directory" do
      for config <- [ignition(), reprovision()],
          u <- units(config),
          text = u["contents"],
          is_binary(text),
          not (text =~ ~r/^User=/m) do
        refute text =~ ~r{^Exec[A-Za-z]*=.*/srv/crew/agent/}m, u["name"]
      end
    end

    test "crew-vmctl's socket is for _crewagent only" do
      assert contents(ignition(), "/etc/crew-box/root-units.sh") =~ "crew-vmctl.socket"

      [socket] =
        Crew.AgentReleaseFixtures.agent_entries("0")
        |> Enum.filter(fn {path, _} -> path == "etc/systemd/crew-vmctl.socket" end)
        |> Enum.map(&elem(&1, 1))

      assert socket =~ "SocketGroup=_crewagent"
      assert socket =~ "SocketMode=0660"
      assert Enum.any?(ignition()["passwd"]["groups"], &(&1["name"] == "_crewagent"))
    end

    test "crew_cache runs as crewcache, binding 53 and 443 and kept by the OOM killer" do
      config = ignition()
      assert unit(config, "crew-cache.service")["enabled"]
      cache = body(config, "crew-cache.service")

      for line <- [
            "User=crewcache",
            "AmbientCapabilities=CAP_NET_BIND_SERVICE",
            "OOMScoreAdjust=-900",
            "RequiresMountsFor=/srv/crew",
            "ExecStart=/srv/crew/agent/current/cache/bin/crew_cache start",
            "EnvironmentFile=-/run/crew-box/cache.env",
            "EnvironmentFile=-/srv/crew/cache/env"
          ] do
        assert cache =~ line, line
      end
    end

    test "the users and groups, with fixed ids so a new OS disk owns the data disk's files" do
      config = ignition()
      users = Map.new(config["passwd"]["users"], &{&1["name"], &1})
      groups = Map.new(config["passwd"]["groups"], &{&1["name"], &1})

      assert %{"uid" => _, "groups" => ["crewvm"], "primaryGroup" => "_crewagent"} =
               users["_crewagent"]

      assert %{"uid" => _, "primaryGroup" => "crewcache"} = users["crewcache"]
      assert Map.keys(groups) |> Enum.sort() == ["_crewagent", "crewcache", "crewvm"]
      assert Enum.all?(Map.values(groups), &is_integer(&1["gid"]))
      assert users["core"]["sshAuthorizedKeys"] == @opts.ssh_keys
    end

    test "core gets no keys when none were given" do
      config = ignition(ssh_keys: [])
      refute Enum.any?(config["passwd"]["users"], &(&1["name"] == "core"))
    end
  end

  test "sets the clock from the RTC on Apple's hypervisor only, every 10 s" do
    config = ignition(type: "mac-vm")
    timer = body(config, "crew-clock-sync.timer")
    assert unit(config, "crew-clock-sync.timer")["enabled"]
    assert timer =~ "OnUnitActiveSec=10s"
    assert timer =~ "ConditionVirtualization=apple"
    assert body(config, "crew-clock-sync.service") =~ "ConditionVirtualization=apple"

    assert contents(config, "/etc/crew-box/clock-sync.sh") =~
             "/sys/class/rtc/rtc0/since_epoch"
  end

  describe "secrets and Flatcar's noexec /etc" do
    test "no file anyone but root can read holds a secret" do
      for config <- [ignition(), ignition(type: "linux-metal", data_disk: "/dev/sdb")] do
        for f <- files(config), text = decode(f), is_binary(text) do
          if text =~ "cj_secret-join-token" or text =~ "tskey-auth-secret-key" do
            assert f["mode"] == 0o600,
                   "#{f["path"]} holds a secret and is #{inspect(f["mode"], base: :octal)}"
          end
        end

        dir = Enum.find(config["storage"]["directories"], &(&1["path"] == "/etc/crew-box"))
        assert dir["mode"] == 0o700
      end
    end

    test "no unit executes a file under /etc directly" do
      for config <- [ignition(), reprovision()],
          u <- units(config),
          text <- [u["contents"] | Enum.map(u["dropins"] || [], & &1["contents"])],
          is_binary(text),
          line <- String.split(text, "\n"),
          String.match?(line, ~r/^Exec[A-Za-z]*=/),
          line =~ "/etc/" do
        assert line =~ ~r{^Exec[A-Za-z]*=-?/bin/sh /etc/crew-box/},
               "#{u["name"]}: #{line}"
      end
    end

    test "nothing under /etc is executable" do
      for f <- files(ignition()), String.starts_with?(f["path"], "/etc/") do
        assert Bitwise.band(f["mode"], 0o111) == 0,
               "#{f["path"]} is #{inspect(f["mode"], base: :octal)}"
      end
    end
  end

  describe "the reprovision Ignition (§12.2)" do
    test "carries no join token, no Tailscale key, and doesn't provision" do
      config = reprovision()
      text = config |> Jason.encode!()
      refute text =~ "cj_"
      refute text =~ "tskey"
      refute file?(config, "/etc/crew-box/provision.env")
      refute file?(config, "/etc/crew-box/tailscale-authkey")
      refute unit?(config, "crew-provision.service")
    end

    test "mounts the existing data disk and starts the installed agent" do
      config = reprovision()
      assert unit(config, "srv-crew.mount")["enabled"]
      assert unit(config, "crew-agent.service")["enabled"]
      assert unit(config, "crew-root-units.service")["enabled"]
      assert unit(config, "crew-cache.service")["enabled"]
      assert unit(config, "crew-box-status.service")["enabled"]
      assert contents(config, "/etc/crew-box/status.sh") =~ ~s[say "agent started]
      assert contents(config, "/etc/crew-box/box.env") =~ ~s(CREW_BOX_NAME="m3max")
    end

    test "for bare metal, still on the given data disk" do
      config = reprovision(type: "linux-metal", data_disk: "/dev/nvme1n1")
      assert body(config, "crew-format-data.service") =~ "format-data.sh /dev/nvme1n1"
    end
  end

  describe "refuses" do
    test "an architecture Flatcar doesn't ship" do
      assert {:error, :bad_arch} = Flatcar.ignition(%{@opts | arch: "riscv64"})
      assert {:error, :bad_arch} = Flatcar.ignition(%{@opts | arch: "x86_64"})
    end

    test "a key that isn't an SSH public key" do
      assert {:error, :bad_ssh_key} =
               Flatcar.ignition(%{@opts | ssh_keys: ["not a key\nwith a newline"]})
    end

    test "a name that isn't a box name, or a box type that isn't Flatcar's" do
      assert {:error, :bad_name} = Flatcar.ignition(%{@opts | name: "Not OK"})
      assert {:error, :bad_type} = Flatcar.ignition(%{@opts | type: "mac-vz"})
    end
  end

  test "reads its pins from images/flatcar/VERSION" do
    pins = Flatcar.pins()
    assert pins["FLATCAR_VERSION"] =~ ~r/^\d+\.\d+\.\d+$/

    for key <-
          ~w(FLATCAR_IMAGE_SHA512_AMD64 FLATCAR_IMAGE_SHA512_ARM64 FLATCAR_KERNEL_SHA512_AMD64 FLATCAR_KERNEL_SHA512_ARM64) do
      assert pins[key] =~ ~r/^[0-9a-f]{128}$/, key
    end

    for key <-
          ~w(FLATCAR_VERITY_AMD64 FLATCAR_VERITY_ARM64 TAILSCALE_SYSEXT_SHA256_AMD64 TAILSCALE_SYSEXT_SHA256_ARM64 VFKIT_SHA256) do
      assert pins[key] =~ ~r/^[0-9a-f]{64}$/, key
    end
  end
end
