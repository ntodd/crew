defmodule Crew.Boxes.FlatcarCacheVMTest do
  @moduledoc """
  The `mac-vz` box's cache VM (§12.1, §12.3, §15.6): Flatcar running
  crew_cache in box mode, served on the VM's address to the Mac alone,
  with Flatcar's update flag and nothing else: no agent, no Tailscale,
  no crew-vmctl.
  """
  use ExUnit.Case, async: true

  alias Crew.Boxes.Flatcar

  @release_key :binary.copy(<<7>>, 32)
  @sha_cache String.duplicate("c", 64)
  @token "cm_mgmt-token-0123456789abcdef0123456789"

  @opts %{
    mode: :provision,
    arch: "arm64",
    ssh_keys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore crew-box@m1"],
    mgmt_token: @token,
    release_key: @release_key,
    release: %{
      version: "0.3.0",
      cache: %{
        url: "https://example.test/crew-cache-0.3.0-linux-arm64.tar.gz",
        sha256: @sha_cache,
        signature: "c2lnLWNhY2hl"
      }
    }
  }

  defp ignition(overrides \\ %{}) do
    assert {:ok, config} = Flatcar.cachevm_ignition(Map.merge(@opts, Map.new(overrides)))
    config |> Jason.encode!() |> Jason.decode!()
  end

  defp reprovision,
    do: ignition(%{mode: :reprovision, mgmt_token: nil, release: nil})

  defp files(config), do: config["storage"]["files"]
  defp file?(config, path), do: Enum.any?(files(config), &(&1["path"] == path))

  defp file(config, path) do
    Enum.find(files(config), &(&1["path"] == path)) ||
      flunk("no #{path} in #{inspect(Enum.map(files(config), & &1["path"]))}")
  end

  defp contents(config, path) do
    %{"contents" => %{"source" => "data:;base64," <> data}} = file(config, path)
    Base.decode64!(data)
  end

  defp units(config), do: config["systemd"]["units"]
  defp unit?(config, name), do: Enum.any?(units(config), &(&1["name"] == name))

  defp body(config, name),
    do: (Enum.find(units(config), &(&1["name"] == name)) || flunk("no unit #{name}"))["contents"]

  test "is Ignition 3.4 and names the VM crew-cache" do
    config = ignition()
    assert config["ignition"]["version"] == "3.4.0"
    assert contents(config, "/etc/hostname") == "crew-cache\n"
  end

  test "runs crew_cache and Flatcar's update flag, and no agent, Tailscale or crew-vmctl" do
    config = ignition()

    for name <-
          ~w(srv-crew.mount crew-format-data.service crew-cachevm-install.service
             crew-cachevm-net.service crew-cache.service crew-cachevm-status.service
             crew-flatcar-update.service crew-flatcar-update.timer
             crew-clock-sync.service crew-clock-sync.timer),
        do: assert(unit?(config, name), name)

    for name <-
          ~w(crew-agent.service crew-agent-install.service crew-provision.service
             tailscaled.service crew-sysext-update.timer crew-root-units.service
             crew-root-install.path crew-quota.service),
        do: refute(unit?(config, name), name)

    refute Enum.any?(files(config), &String.contains?(&1["path"], "tailscale"))
    assert config["storage"]["links"] in [nil, []]
    assert contents(config, "/etc/flatcar/update.conf") == "REBOOT_STRATEGY=off\n"

    for masked <- ~w(docker.socket docker.service containerd.service),
        do: assert(Enum.find(units(config), &(&1["name"] == masked))["mask"])
  end

  test "the management token is root's alone, and survives a new OS disk on the data disk" do
    config = ignition()
    token = file(config, "/etc/crew-box/cache-mgmt.env")
    assert token["mode"] == 0o600

    assert contents(config, "/etc/crew-box/cache-mgmt.env") ==
             ~s(CREW_CACHE_MGMT_TOKEN="#{@token}"\n)

    install = contents(config, "/etc/crew-box/cachevm-install.sh")
    assert install =~ "$data/cachevm/mgmt.env"
    assert body(config, "crew-cache.service") =~ "EnvironmentFile=/srv/crew/cachevm/mgmt.env"
  end

  test "crew_cache listens on 10.199.0.1, management included, as crewcache" do
    unit = body(ignition(), "crew-cache.service")
    assert unit =~ "User=crewcache"
    assert unit =~ "CREW_CACHE_MGMT_LISTEN=10.199.0.1:7780"
    assert unit =~ "AmbientCapabilities=CAP_NET_BIND_SERVICE"
    assert unit =~ "ExecStart=/srv/crew/release/current/bin/crew_cache start"
    assert unit =~ "ConditionPathExists=/srv/crew/release/current/bin/crew_cache"
    assert unit =~ ~r/Requires=.*crew-cachevm-net\.service/
    assert unit =~ "ReadWritePaths=/srv/crew/cache"
  end

  test "serves 10.199.0.1 on the VM's address to the Mac only, by DNAT, and drops the rest" do
    net = contents(ignition(), "/etc/crew-box/cachevm-net.sh")
    assert net =~ "ip link add crew0 type dummy"
    assert net =~ "10.199.0.1/32"
    assert net =~ "dnat ip to 10.199.0.1"
    assert net =~ ~r/tcp dport \{ 53, 80, 443, 7780 \}/
    # The Mac is the vmnet gateway: the only source let in.
    assert net =~ "ip saddr $gw"
    assert net =~ "policy drop"
  end

  test "installs the release's cache, checked against its digest and the release key" do
    config = ignition()
    release = contents(config, "/etc/crew-box/release.env")
    assert release =~ ~s(CREW_VERSION="0.3.0")
    assert release =~ ~s(CREW_TARGET="linux-arm64")
    assert release =~ ~s(CREW_CACHE_SHA256="#{@sha_cache}")
    refute release =~ "CREW_AGENT_URL"
    assert file?(config, "/etc/crew-box/release-key.pem")

    install = contents(config, "/etc/crew-box/cachevm-install.sh")
    assert install =~ "check_release cache"

    assert body(config, "crew-cachevm-install.service") =~
             "/bin/sh /etc/crew-box/cachevm-install.sh"
  end

  test "says on the consoles when the cache answers, for the launcher" do
    config = ignition()
    assert contents(config, "/etc/crew-box/cachevm-status.sh") =~ "say \"cache ready"
    assert body(config, "crew-cachevm-status.service") =~ "After=crew-cache.service"
  end

  test "a reprovision carries no token and no release: the data disk has both" do
    config = reprovision()
    refute file?(config, "/etc/crew-box/cache-mgmt.env")
    refute file?(config, "/etc/crew-box/release.env")
    assert unit?(config, "crew-cache.service")
  end

  test "crewcache is the only user, with the boxes' fixed id; core gets the keys" do
    passwd = ignition()["passwd"]
    assert [%{"name" => "crewcache", "uid" => 9101}, %{"name" => "core"}] = passwd["users"]
  end

  test "routes nothing" do
    sysctls = contents(ignition(), "/etc/sysctl.d/90-crew.conf")
    refute sysctls =~ "ip_forward = 1"
    assert sysctls =~ "net.ipv6.conf.default.accept_ra = 0"
  end

  test "refuses what it can't use" do
    assert {:error, :bad_arch} = Flatcar.cachevm_ignition(%{@opts | arch: "amd64"})
    assert {:error, :bad_ssh_key} = Flatcar.cachevm_ignition(%{@opts | ssh_keys: ["nope"]})
    assert {:error, :bad_token} = Flatcar.cachevm_ignition(%{@opts | mgmt_token: "short"})
    assert {:error, :no_release} = Flatcar.cachevm_ignition(%{@opts | release: nil})
    assert {:error, :no_release_key} = Flatcar.cachevm_ignition(%{@opts | release_key: nil})
  end
end
