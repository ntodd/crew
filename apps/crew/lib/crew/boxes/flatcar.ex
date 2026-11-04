defmodule Crew.Boxes.Flatcar do
  @moduledoc """
  The Ignition (3.4.0) for a box that runs Flatcar Container Linux
  (§12.1, §12.2): `linux-metal` on the machine itself, `linux-vm` and
  `mac-vm` as a VM the launchers boot (`priv/agent/*-vm.sh`). Built as a
  map, JSON-ready, as Foreman's `Boxes.Flatcar` builds it, rather than
  rendered from Butane: there's no Butane binary to ship or pin, and the
  tests read the map.

  The box gets:

  - **Flatcar's settings:** `REBOOT_STRATEGY=off`, an applied OS update
    flagged in `/run/reboot-required*` every minute, the sysctls, Docker
    masked.
  - **Tailscale** from Flatcar's sysext bakery, pinned by digest, updated
    daily and flagged like an OS update; its state on the data disk.
  - **The data disk** at `/srv/crew` (XFS, reflink, project quotas),
    formatted only when it's empty and mounted by its label, laid out
    with three quota areas (§12.4) on every boot.
  - **`crew0`** with 10.199.0.1/32 and the agent release's firewall.
  - **The first boot** (`crew-provision`): the tailnet, the control
    plane, the agent's install from the release (checked against its
    SHA-256s and the release key the Ignition embeds), the enrollment,
    and then the secrets deleted.
  - **The agent** (`_crewagent`), **crew_cache** (`crewcache`) and
    **crew-vmctl** (socket-activated, root) as §10.8 has them.

  Flatcar mounts `/etc` noexec, so every script is written there 0644
  and run as `/bin/sh /etc/crew-box/<script>`; binaries run from
  `/srv/crew/agent/current`. The scripts are `priv/flatcar/`.

  **Reprovision** (`mode: :reprovision`) is the same box without a join
  token, a Tailscale key or a release: for a new OS disk over the data
  disk it had, which keeps the agent, its identity and the tailnet node.

  The pins are `images/flatcar/VERSION`'s, compiled in.
  """

  @version_file Path.expand("../../../../../images/flatcar/VERSION", __DIR__)
  @external_resource @version_file

  @pins for line <- @version_file |> File.read!() |> String.split("\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            [key, value] = String.split(line, "=", parts: 2),
            into: %{},
            do: {key, value}

  @scripts_dir Path.expand("../../../priv/flatcar", __DIR__)
  @script_names ~w(lib.sh provision.sh agent-install.sh format-data.sh quota.sh net.sh
                   agent-rollback.sh flatcar-update-check update-sysexts.sh clock-sync.sh status.sh)
  for name <- @script_names, do: @external_resource(Path.join(@scripts_dir, name))
  @scripts Map.new(@script_names, &{&1, File.read!(Path.join(@scripts_dir, &1))})

  @bakery "https://extensions.flatcar.org/extensions"
  @bakery_arch %{"amd64" => "x86-64", "arm64" => "arm64"}
  @types ~w(linux-metal linux-vm mac-vm)

  # Fixed ids, so a new OS disk (reprovisioning) owns the data disk's
  # files: well clear of Flatcar's own users, core (500) and the job VMs'
  # 200000 + lease (§11.3).
  @agent_uid 9100
  @cache_uid 9101
  @crewvm_gid 9110

  @ssh_key ~r/\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+\/=]+( [^\r\n]*)?\z/
  @data_disk ~r"\A/dev/(?!.*\.\.)[A-Za-z0-9._:/-]{1,120}\z"

  @type artifact :: %{url: String.t(), sha256: String.t(), signature: String.t()}
  @type opts :: %{
          required(:mode) => :provision | :reprovision,
          required(:name) => String.t(),
          required(:type) => String.t(),
          required(:arch) => String.t(),
          optional(:data_disk) => String.t() | nil,
          optional(:ssh_keys) => [String.t()],
          optional(:url) => String.t(),
          optional(:join_token) => String.t(),
          optional(:tailscale_auth_key) => String.t() | nil,
          optional(:release) =>
            %{version: String.t(), agent: artifact(), cache: artifact()} | nil,
          optional(:release_key) => binary() | nil,
          optional(:dev) => boolean()
        }

  @doc "The pins in `images/flatcar/VERSION`, by key."
  def pins, do: @pins

  @doc "The architectures Flatcar ships, as its release server names them."
  def arches, do: Map.keys(@bakery_arch)

  @doc "The box types that run Flatcar."
  def types, do: @types

  @doc "The data disk the launchers give their VM (§12.2)."
  def vm_data_disk, do: "/dev/vdb"

  @doc "Whether `path` is a data disk device Add box accepts (`/dev/...`)."
  def data_disk?(path), do: is_binary(path) and Regex.match?(@data_disk, path)

  @doc "Whether `key` is one SSH public key line."
  def ssh_key?(key), do: is_binary(key) and Regex.match?(@ssh_key, key)

  @doc "The agent release target for a Flatcar arch."
  def target("amd64"), do: "linux-amd64"
  def target("arm64"), do: "linux-arm64"

  @doc """
  The Ignition config for a box (a map, JSON-ready). See `t:opts/0`;
  `:data_disk` is for `linux-metal` only (the VMs' is `/dev/vdb`), and
  `:ssh_keys` go to `core`.
  """
  @spec ignition(opts()) :: {:ok, map()} | {:error, atom()}
  def ignition(opts) do
    opts = Map.update(opts, :ssh_keys, [], fn keys -> Enum.map(keys || [], &String.trim/1) end)

    checks =
      [
        bad_mode: opts.mode in [:provision, :reprovision],
        bad_name: CrewProtocol.Names.box_name?(opts.name),
        bad_type: opts.type in @types,
        bad_arch: Map.has_key?(@bakery_arch, opts.arch),
        bad_ssh_key: Enum.all?(opts.ssh_keys, &ssh_key?/1),
        bad_data_disk: data_disk?(data_disk(opts))
      ] ++ if(opts.mode == :provision, do: provision_checks(opts), else: [])

    case Enum.find(checks, fn {_error, ok?} -> not ok? end) do
      nil -> {:ok, build(opts)}
      {error, false} -> {:error, error}
    end
  end

  # What only a first boot needs: the control plane, the token, the
  # release and the key it's checked against.
  defp provision_checks(opts) do
    [
      bad_url: url?(opts[:url]),
      invalid_token: is_binary(opts[:join_token]),
      no_release: release?(opts[:release]),
      no_release_key: match?(<<_::binary-size(32)>>, opts[:release_key])
    ]
  end

  defp data_disk(%{type: "linux-metal"} = opts), do: opts[:data_disk]
  defp data_disk(_opts), do: vm_data_disk()

  defp url?(url) do
    case is_binary(url) && URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end

  defp release?(%{version: v, agent: agent, cache: cache}) when is_binary(v),
    do: artifact?(agent) and artifact?(cache)

  defp release?(_), do: false

  defp artifact?(%{url: url, sha256: sha, signature: sig}),
    do: is_binary(url) and is_binary(sig) and is_binary(sha) and sha =~ ~r/\A[0-9a-f]{64}\z/

  defp artifact?(_), do: false

  # -- the config ----------------------------------------------------------------

  defp build(opts) do
    provision? = opts.mode == :provision
    {sysext, sysext_link} = tailscale_sysext(opts.arch)

    files =
      [
        text("/etc/hostname", opts.name <> "\n"),
        text("/etc/flatcar/update.conf", "REBOOT_STRATEGY=off\n"),
        text("/etc/default/tailscaled", ~s(PORT="41641"\nFLAGS=""\n)),
        text(
          "/etc/systemd/network/zz-default.network.d/crew-dhcp.conf",
          "[DHCPv4]\nClientIdentifier=mac\n"
        ),
        text(
          "/etc/systemd/network/00-crew.network",
          "[Match]\nName=crewt* crew0\n\n[Link]\nUnmanaged=yes\n"
        ),
        text("/etc/sysctl.d/90-crew.conf", sysctls()),
        text("/etc/modules-load.d/crew.conf", "nf_conntrack\ndummy\n"),
        text("/etc/sysupdate.tailscale.d/tailscale.conf", sysupdate()),
        sysext,
        text("/etc/crew-box/box.env", env(CREW_BOX_NAME: opts.name, CREW_BOX_TYPE: opts.type))
      ] ++
        for({name, script} <- @scripts, do: text("/etc/crew-box/#{name}", script)) ++
        if(provision?, do: provision_files(opts), else: [])

    %{
      "ignition" => %{"version" => "3.4.0"},
      "passwd" => passwd(opts.ssh_keys),
      "storage" => %{
        "directories" => [%{"path" => "/etc/crew-box", "mode" => 0o700}],
        "files" => files,
        "links" => [sysext_link]
      },
      "systemd" => %{"units" => units(opts, provision?)}
    }
  end

  defp provision_files(opts) do
    release = opts.release
    key = opts.release_key

    [
      secret(
        "/etc/crew-box/provision.env",
        env(CREW_URL: opts.url, CREW_JOIN_TOKEN: opts.join_token, CREW_BOX_NAME: opts.name)
      ),
      text(
        "/etc/crew-box/release.env",
        env(
          [
            CREW_VERSION: release.version,
            CREW_TARGET: target(opts.arch),
            CREW_AGENT_URL: release.agent.url,
            CREW_AGENT_SHA256: release.agent.sha256,
            CREW_AGENT_SIG: release.agent.signature,
            CREW_CACHE_URL: release.cache.url,
            CREW_CACHE_SHA256: release.cache.sha256,
            CREW_CACHE_SIG: release.cache.signature,
            CREW_AGENT_SOCKET_URL: socket_url(opts.url),
            CREW_RELEASE_PUBLIC_KEY: Base.encode64(key),
            CREW_RELEASE_KEY_FINGERPRINT: CrewProtocol.Auth.fingerprint(key)
          ] ++ if(dev?(opts), do: [CREW_DEV: "1"], else: [])
        )
      ),
      text("/etc/crew-box/release-key.pem", public_key_pem(key))
    ] ++
      case opts[:tailscale_auth_key] do
        key when is_binary(key) and key != "" -> [secret("/etc/crew-box/tailscale-authkey", key)]
        _ -> []
      end
  end

  # ws:// only for a development control plane on plain HTTP (§5.3): the
  # agent refuses it otherwise.
  defp dev?(opts), do: opts[:dev] == true and String.starts_with?(opts.url, "http://")

  @doc "The agent's socket URL for a control plane's base URL."
  def socket_url(base) do
    base
    |> String.trim_trailing("/")
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> Kernel.<>("/agent/websocket")
  end

  # An ed25519 SubjectPublicKeyInfo: a fixed 12-byte DER prefix, then the
  # key, as openssl reads it.
  defp public_key_pem(key) do
    der = <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>> <> key
    "-----BEGIN PUBLIC KEY-----\n#{Base.encode64(der)}\n-----END PUBLIC KEY-----\n"
  end

  defp sysctls do
    """
    # Crew (docs/crew_spec.md §12.1): job VMs are routed, not bridged.
    net.ipv4.ip_forward = 1
    net.ipv6.conf.all.forwarding = 0
    net.ipv6.conf.default.accept_ra = 0
    # The host VM needs none.
    user.max_user_namespaces = 0
    vm.swappiness = 0
    -net.netfilter.nf_conntrack_max = 262144
    """
  end

  defp tailscale_sysext(arch) do
    version = @pins["TAILSCALE_SYSEXT_VERSION"]
    image = "tailscale-#{version}-#{@bakery_arch[arch]}.raw"
    path = "/opt/extensions/tailscale/#{image}"

    file = %{
      "path" => path,
      "mode" => 0o644,
      "contents" => %{
        "source" => "#{@bakery}/#{image}",
        "verification" => %{
          "hash" => "sha256-" <> @pins["TAILSCALE_SYSEXT_SHA256_#{String.upcase(arch)}"]
        }
      }
    }

    {file, %{"path" => "/etc/extensions/tailscale.raw", "target" => path, "hard" => false}}
  end

  defp sysupdate do
    """
    [Transfer]
    Verify=false

    [Source]
    Type=url-file
    Path=#{@bakery}/tailscale/
    MatchPattern=tailscale-@v-%a.raw

    [Target]
    InstancesMax=3
    Type=regular-file
    Path=/opt/extensions/tailscale
    CurrentSymlink=/etc/extensions/tailscale.raw
    """
  end

  defp passwd(ssh_keys) do
    system = %{
      "noCreateHome" => true,
      "shell" => "/usr/sbin/nologin",
      "system" => true,
      "noUserGroup" => true
    }

    users = [
      Map.merge(system, %{
        "name" => "_crewagent",
        "uid" => @agent_uid,
        "primaryGroup" => "_crewagent",
        "groups" => ["crewvm"],
        "homeDir" => "/srv/crew/agent",
        "gecos" => "Crew agent"
      }),
      Map.merge(system, %{
        "name" => "crewcache",
        "uid" => @cache_uid,
        "primaryGroup" => "crewcache",
        "homeDir" => "/srv/crew/cache",
        "gecos" => "Crew registry cache"
      })
    ]

    core = if ssh_keys == [], do: [], else: [%{"name" => "core", "sshAuthorizedKeys" => ssh_keys}]

    %{
      "groups" => [
        %{"name" => "_crewagent", "gid" => @agent_uid, "system" => true},
        %{"name" => "crewcache", "gid" => @cache_uid, "system" => true},
        %{"name" => "crewvm", "gid" => @crewvm_gid, "system" => true}
      ],
      "users" => users ++ core
    }
  end

  # -- units ---------------------------------------------------------------------

  defp units(opts, provision?) do
    disk = data_disk(opts)

    [
      unit("srv-crew.mount", srv_crew_mount()),
      unit("crew-format-data.service", format_data(disk), enabled: false),
      unit("crew-quota.service", quota()),
      unit("crew-net.service", net()),
      unit("crew-agent-install.service", agent_install(), enabled: false),
      unit("crew-agent.service", agent()),
      unit("crew-agent-rollback.service", agent_rollback(), enabled: false),
      unit("crew-vmctl.socket", vmctl_socket()),
      unit("crew-vmctl@.service", vmctl_service(), enabled: false),
      unit("crew-cache.service", cache()),
      unit("crew-box-status.service", status()),
      %{
        "name" => "tailscaled.service",
        "enabled" => true,
        "dropins" => [%{"name" => "10-crew.conf", "contents" => tailscaled_dropin()}]
      },
      unit("crew-sysext-update.service", sysext_update(), enabled: false),
      unit("crew-sysext-update.timer", sysext_update_timer()),
      unit("crew-flatcar-update.service", flatcar_update(), enabled: false),
      unit("crew-flatcar-update.timer", flatcar_update_timer()),
      unit("crew-clock-sync.service", clock_sync(), enabled: false),
      unit("crew-clock-sync.timer", clock_sync_timer()),
      %{"name" => "docker.socket", "mask" => true},
      %{"name" => "docker.service", "mask" => true},
      %{"name" => "containerd.service", "mask" => true}
    ] ++ if(provision?, do: [unit("crew-provision.service", provision())], else: [])
  end

  # Units without an [Install] section are pulled in by others, and
  # Ignition leaves their enablement alone.
  defp unit(name, contents, opts \\ []) do
    if Keyword.get(opts, :enabled, true),
      do: %{"name" => name, "enabled" => true, "contents" => contents},
      else: %{"name" => name, "contents" => contents}
  end

  defp srv_crew_mount do
    """
    [Unit]
    Description=Crew's data disk
    Requires=crew-format-data.service
    After=crew-format-data.service

    [Mount]
    What=/dev/disk/by-label/crew-data
    Where=/srv/crew
    Type=xfs
    Options=defaults,noatime,prjquota,nofail

    [Install]
    WantedBy=local-fs.target
    """
  end

  defp format_data(disk) do
    device = device_unit(disk)

    """
    [Unit]
    Description=Format Crew's data disk if it's empty
    DefaultDependencies=no
    BindsTo=#{device}
    After=#{device}
    Before=srv-crew.mount shutdown.target
    Conflicts=shutdown.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh /etc/crew-box/format-data.sh #{disk}
    """
  end

  defp quota do
    """
    [Unit]
    Description=Lay out Crew's data disk and its quotas
    RequiresMountsFor=/srv/crew
    Requires=srv-crew.mount
    After=srv-crew.mount

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh /etc/crew-box/quota.sh

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp net do
    """
    [Unit]
    Description=Crew's service address and firewall
    RequiresMountsFor=/srv/crew
    After=crew-quota.service crew-agent-install.service network-pre.target
    Before=crew-agent.service crew-cache.service
    ConditionPathExists=/srv/crew/agent/current/etc/nft.conf

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh /etc/crew-box/net.sh

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp provision do
    """
    [Unit]
    Description=Join the tailnet, install the Crew agent and enroll this box
    ConditionPathExists=/etc/crew-box/provision.env
    Wants=network-online.target tailscaled.service
    After=network-online.target tailscaled.service crew-quota.service
    RequiresMountsFor=/srv/crew
    StartLimitIntervalSec=0

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /etc/crew-box/provision.sh
    Restart=on-failure
    RestartSec=30
    # The script writes its progress to the consoles itself.
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp agent_install do
    """
    [Unit]
    Description=Install the Crew agent and crew_cache from the release
    RequiresMountsFor=/srv/crew
    Wants=network-online.target
    After=network-online.target crew-quota.service
    ConditionPathExists=!/srv/crew/agent/current
    ConditionPathExists=/etc/crew-box/release.env

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/sh /etc/crew-box/agent-install.sh
    StandardOutput=journal
    StandardError=journal
    """
  end

  # Foreman's foreman-agent.service, as _crewagent (§10.8). The release
  # is root's; RELEASE_TMP is where the release writes its runtime config.
  defp agent do
    """
    [Unit]
    Description=Crew agent
    Wants=network-online.target
    After=network-online.target crew-net.service crew-agent-install.service crew-vmctl.socket
    Requires=crew-net.service
    Wants=crew-vmctl.socket crew-cache.service
    RequiresMountsFor=/srv/crew
    ConditionPathExists=/srv/crew/agent/current/bin/crew_agent
    OnFailure=crew-agent-rollback.service
    StartLimitIntervalSec=120
    StartLimitBurst=5

    [Service]
    User=_crewagent
    Group=_crewagent
    SupplementaryGroups=crewvm
    EnvironmentFile=/srv/crew/agent/env
    Environment=HOME=/srv/crew/agent RELEASE_TMP=/run/crew-agent RELEASE_DISTRIBUTION=none
    RuntimeDirectory=crew-agent
    RuntimeDirectoryMode=0700
    WorkingDirectory=/run/crew-agent
    ExecStart=/srv/crew/agent/current/bin/crew_agent start
    Restart=always
    RestartSec=3
    OOMScoreAdjust=-900
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    ReadWritePaths=/srv/crew/agent /srv/crew/vms /srv/crew/images
    ProtectKernelModules=true
    ProtectKernelLogs=true
    ProtectClock=true
    RestrictSUIDSGID=true
    LockPersonality=true
    CapabilityBoundingSet=
    AmbientCapabilities=

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp agent_rollback do
    """
    [Unit]
    Description=Roll the Crew agent back to its previous release

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /etc/crew-box/agent-rollback.sh
    """
  end

  # §10.8: one JSON request per connection, from _crewagent only.
  defp vmctl_socket do
    """
    [Unit]
    Description=Crew's root helper (crew-vmctl)

    [Socket]
    ListenStream=/run/crew/vmctl.sock
    SocketUser=root
    SocketGroup=_crewagent
    SocketMode=0660
    DirectoryMode=0755
    Accept=yes
    MaxConnections=64

    [Install]
    WantedBy=sockets.target
    """
  end

  # The connection is fd 3 ($LISTEN_FDS) and stdin/stdout.
  defp vmctl_service do
    """
    [Unit]
    Description=Crew's root helper (crew-vmctl), one request
    RequiresMountsFor=/srv/crew
    CollectMode=inactive-or-failed

    [Service]
    ExecStart=/srv/crew/agent/current/bin/crew-vmctl
    Environment=CREW_DATA_DIR=/srv/crew
    StandardInput=socket
    StandardOutput=socket
    StandardError=journal
    RuntimeMaxSec=300
    """
  end

  defp cache do
    """
    [Unit]
    Description=Crew's registry cache (crew_cache)
    Wants=network-online.target
    After=network-online.target crew-net.service crew-quota.service
    Requires=crew-net.service
    RequiresMountsFor=/srv/crew
    ConditionPathExists=/srv/crew/agent/current/cache/bin/crew_cache

    [Service]
    User=crewcache
    Group=crewcache
    # Its share of the disk (crew-quota), then the agent's and admin's settings.
    EnvironmentFile=-/run/crew-box/cache.env
    EnvironmentFile=-/srv/crew/cache/env
    Environment=HOME=/srv/crew/cache CREW_DATA_DIR=/srv/crew RELEASE_TMP=/run/crew-cache RELEASE_DISTRIBUTION=none
    RuntimeDirectory=crew-cache
    RuntimeDirectoryMode=0700
    WorkingDirectory=/run/crew-cache
    ExecStart=/srv/crew/agent/current/cache/bin/crew_cache start
    Restart=always
    RestartSec=3
    AmbientCapabilities=CAP_NET_BIND_SERVICE
    CapabilityBoundingSet=CAP_NET_BIND_SERVICE
    OOMScoreAdjust=-900
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    ReadWritePaths=/srv/crew/cache

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp status do
    """
    [Unit]
    Description=Say how the box's boot went, on the consoles
    After=crew-agent.service srv-crew.mount
    ConditionPathExists=!/etc/crew-box/provision.env

    [Service]
    Type=oneshot
    # Give the agent a moment to fail if it's going to.
    ExecStartPre=/bin/sleep 5
    ExecStart=/bin/sh /etc/crew-box/status.sh

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp tailscaled_dropin do
    """
    [Unit]
    # Its state is on the data disk, so a new OS disk keeps the node.
    RequiresMountsFor=/srv/crew
    Requires=crew-quota.service
    After=crew-quota.service

    [Service]
    BindPaths=/srv/crew/tailscale:/var/lib/tailscale
    """
  end

  defp sysext_update do
    """
    [Unit]
    Description=Update the Tailscale system extension
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /etc/crew-box/update-sysexts.sh
    """
  end

  defp sysext_update_timer do
    """
    [Unit]
    Description=Update the Tailscale system extension daily

    [Timer]
    OnCalendar=daily
    RandomizedDelaySec=1h
    Persistent=true

    [Install]
    WantedBy=timers.target
    """
  end

  defp flatcar_update do
    """
    [Unit]
    Description=Flag a Flatcar update waiting for a reboot
    After=update-engine.service

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /etc/crew-box/flatcar-update-check
    """
  end

  defp flatcar_update_timer do
    """
    [Unit]
    Description=Check for a Flatcar update waiting for a reboot

    [Timer]
    OnBootSec=1min
    OnUnitActiveSec=1min

    [Install]
    WantedBy=timers.target
    """
  end

  defp clock_sync do
    """
    [Unit]
    Description=Set the clock from the RTC after the Mac sleeps
    ConditionVirtualization=apple

    [Service]
    Type=oneshot
    ExecStart=/bin/sh /etc/crew-box/clock-sync.sh
    """
  end

  defp clock_sync_timer do
    """
    [Unit]
    Description=Check the clock against the RTC
    ConditionVirtualization=apple

    [Timer]
    OnBootSec=10s
    OnUnitActiveSec=10s
    AccuracySec=1s

    [Install]
    WantedBy=timers.target
    """
  end

  @doc """
  The device unit systemd names for a device path, escaped as
  `systemd-escape --path` escapes it: `/dev/vdb` is `dev-vdb.device`.
  """
  def device_unit(path) do
    escaped =
      path
      |> String.trim("/")
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map_join(fn
        {?/, _} -> "-"
        {?., 0} -> "\\x2e"
        {c, _} when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?:, ?_, ?.] -> <<c>>
        {c, _} -> "\\x" <> String.downcase(Base.encode16(<<c>>))
      end)

    escaped <> ".device"
  end

  # -- files ---------------------------------------------------------------------

  # An env file sourced by sh: inside double quotes only these are special.
  defp env(pairs), do: Enum.map_join(pairs, fn {k, v} -> "#{k}=#{quote_env(v)}\n" end)

  defp quote_env(value),
    do: ~s(") <> String.replace(value, ["\\", "\"", "$", "`"], &("\\" <> &1)) <> ~s(")

  defp text(path, content), do: file(path, content, 0o644)
  defp secret(path, content), do: file(path, content, 0o600)

  defp file(path, content, mode) do
    %{
      "path" => path,
      "mode" => mode,
      "overwrite" => true,
      "contents" => %{"source" => "data:;base64," <> Base.encode64(content)}
    }
  end
end
