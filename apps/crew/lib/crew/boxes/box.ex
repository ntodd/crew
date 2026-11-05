defmodule Crew.Boxes.Box do
  @moduledoc "A machine that runs jobs: one agent, one driver (§3, §22)."
  use Crew.Schema

  @types ~w(linux-metal linux-vm mac-vm mac-vz)

  schema "boxes" do
    field :name, :string
    field :type, :string
    field :driver, :string
    field :guest_arch, :string
    field :public_key, :binary, redact: true
    field :key_fingerprint, :string
    field :agent_version, :string
    field :protocol_version, :integer
    field :desired_agent_version, :string
    field :failed_agent_version, :string
    field :update_state, :map
    field :os, :string
    field :arch, :string
    field :capabilities, :map
    field :pinned_capabilities, :map
    field :needs_approval, :boolean, default: false
    field :allocatable_vcpus_override, :integer
    field :allocatable_memory_mib_override, :integer
    field :reserve_vcpus, :integer, default: 1
    field :reserve_memory_mib, :integer
    field :cpu_overcommit, :float, default: 1.5
    field :max_vms, :integer
    field :draining, :boolean, default: false
    field :drain_reason, :string
    field :reboot_required, :boolean, default: false
    field :reboot_packages, {:array, :string}, default: []
    field :boot_id, :string
    field :os_version, :string
    field :previous_os_version, :string
    field :can_restart, :boolean, default: false
    field :reboot_requested_at, :utc_datetime_usec
    field :reboot_boot_id, :string
    field :reboot_target, :string
    field :cache_vm_reboot, :map
    field :cache_ca_generation, :integer, default: 1
    field :cache_top, {:array, :map}, default: []
    field :quarantined_until, :utc_datetime_usec
    field :consecutive_failures, :integer, default: 0
    field :firewall_ok, :boolean, default: false
    field :virtualized, :boolean, default: false
    field :hypervisor_vendor, :string
    field :sleep_disabled, :boolean
    field :egress_ip, :string
    field :last_repo_ran_at, :map, default: %{}
    field :online_at, :utc_datetime_usec
    field :offline_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def types, do: @types
end
