# For tests/16-reboots.spec.js only (E2E_SEED=seeds/reboots.exs): a
# Flatcar box with a Flatcar update waiting for a reboot, and a mac-vz
# box whose cache VM has one, as their agents would have reported them.
# Neither agent is running: the pages show what was reported.
alias Crew.Boxes.Box

caps = fn driver ->
  %{
    "driver" => driver,
    "driver_version" => "0.1.0",
    "guest_arch" => "arm64",
    "vcpus" => 16,
    "memory_mib" => 65_536,
    "vm_area_mib" => 409_600,
    "max_vcpus_per_vm" => 16,
    "max_memory_mib_per_vm" => 65_536,
    "vmm_overhead_mib" => 64,
    "features" => [],
    "virtualized" => false,
    "hypervisor_vendor" => nil,
    "firewall_ok" => true
  }
end

box = fn name, type, driver, extra ->
  {public, _} = CrewProtocol.Auth.generate_keypair()

  struct(
    Box,
    Map.merge(
      %{
        name: name,
        type: type,
        driver: driver,
        guest_arch: "arm64",
        public_key: public,
        key_fingerprint: CrewProtocol.Auth.fingerprint(public),
        agent_version: "0.1.0",
        protocol_version: CrewProtocol.version(),
        capabilities: caps.(driver),
        pinned_capabilities: caps.(driver),
        firewall_ok: true,
        boot_id: "11111111-1111-4111-8111-111111111111",
        os_version: if(type != "mac-vz", do: "4757.2.3")
      },
      extra
    )
  )
  |> Crew.Repo.insert!()
end

box.("rack1", "linux-metal", "firecracker", %{
  can_restart: true,
  reboot_required: true,
  reboot_packages: ["flatcar-4800.0.0", "tailscale-v1.106.0"]
})

box.("m1ultra", "mac-vz", "vz", %{
  cache_vm_reboot: %{
    "required" => true,
    "packages" => ["flatcar-4800.0.0"],
    "boot_id" => "c1c1c1c1-1111-4111-8111-111111111111"
  }
})
