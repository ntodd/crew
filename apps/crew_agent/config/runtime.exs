import Config

# Agent settings (§21.2) from CREW_* variables, set by the service unit
# from ${CREW_DATA_DIR}/agent/env. Tests configure the agent directly.
if config_env() != :test do
  list = fn name ->
    name |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  int = fn name, default ->
    case System.get_env(name) do
      v when v in [nil, ""] -> default
      v -> String.to_integer(String.trim(v))
    end
  end

  os_driver = if match?({:unix, :darwin}, :os.type()), do: "vz", else: "firecracker"

  os_data_dir =
    if match?({:unix, :darwin}, :os.type()),
      do: "/Library/Application Support/Crew",
      else: "/srv/crew"

  dev = System.get_env("CREW_DEV") == "1"
  driver = System.get_env("CREW_DRIVER", os_driver)

  if driver == "null" and config_env() == :prod do
    raise "CREW_DRIVER=null is for development only; this release doesn't include it (§11.5)"
  end

  config :crew_agent,
    url: System.get_env("CREW_URL"),
    join_token: System.get_env("CREW_JOIN_TOKEN"),
    box_name: System.get_env("CREW_BOX_NAME"),
    driver: driver,
    data_dir: System.get_env("CREW_DATA_DIR", os_data_dir),
    service_ip: System.get_env("CREW_SERVICE_IP", "10.199.0.1"),
    vm_net: System.get_env("CREW_VM_NET", "10.200.0.0/16"),
    uplink: System.get_env("CREW_UPLINK"),
    extra_blocked: list.("CREW_EXTRA_BLOCKED"),
    guest_api_ip: System.get_env("CREW_GUEST_API_IP"),
    guest_api_port: int.("CREW_GUEST_API_PORT", 7777),
    vzd_socket: System.get_env("CREW_VZD_SOCKET"),
    # crew-vmctl's socket (§10.8, native/crew-vmctl).
    vmctl_socket: System.get_env("CREW_VMCTL_SOCKET", "/run/crew/vmctl.sock"),
    vz_host_reserve_vcpus: int.("CREW_VZ_HOST_RESERVE_VCPUS", 2),
    vz_host_reserve_mib: int.("CREW_VZ_HOST_RESERVE_MIB", 8192),
    vz_vm_area_gib: int.("CREW_VZ_VM_AREA_GIB", 400),
    vz_cache: %{
      addr: System.get_env("CREW_VZ_CACHE_ADDR"),
      mac: System.get_env("CREW_VZ_CACHE_MAC"),
      mgmt_port: 7780,
      leases: "/var/db/dhcpd_leases"
    },
    vz_dns_fallback: System.get_env("CREW_VZ_DNS_FALLBACK"),
    vz_mtu: int.("CREW_VZ_MTU", 1500),
    vz_max_conns: int.("CREW_VZ_MAX_CONNS", 1024),
    # §14.2 site4: the site's public egress address (spike S12).
    egress_echo_url: System.get_env("CREW_EGRESS_ECHO_URL", "https://checkip.amazonaws.com"),
    crew_vz_bin: System.get_env("CREW_VZ_BIN", "crew-vz"),
    # Development: image.prepare clones kernel and rootfs.ext4 from here
    # instead of downloading.
    dev_image_dir: if(dev, do: System.get_env("CREW_DEV_IMAGE_DIR")),
    cache_mgmt_url: System.get_env("CREW_CACHE_MGMT_URL"),
    cache_mgmt_token: System.get_env("CREW_CACHE_MGMT_TOKEN"),
    release_public_key: System.get_env("CREW_RELEASE_PUBLIC_KEY"),
    null_guest_cmd: System.get_env("CREW_NULL_GUEST_CMD"),
    # Conformance mode (§11.6): only this box's own env turns it on.
    conformance: System.get_env("CREW_CONFORMANCE") == "1",
    dev: dev,
    connect: System.get_env("CREW_URL") not in [nil, ""]
end
