defmodule CrewAgent.Driver do
  @moduledoc """
  One kind of host: how this box starts, finds and stops job VMs (§11.1).

  - The scheduler never sees a driver's name; it places on capabilities.
  - Drivers never talk to the control plane: the agent owns the
    protocol, the guest API, leases, images and logs.
  - A driver's `stats/1` is the host's view of a VM.
  - Job VMs are never children of the agent process (§10.7): they
    survive agent restarts and updates.
  """

  @type capabilities :: %{
          driver: String.t(),
          driver_version: String.t(),
          guest_arch: String.t(),
          vcpus: pos_integer(),
          memory_mib: pos_integer(),
          vm_area_mib: pos_integer(),
          max_vcpus_per_vm: pos_integer(),
          max_memory_mib_per_vm: pos_integer(),
          vmm_overhead_mib: pos_integer(),
          features: [String.t()],
          virtualized: boolean(),
          hypervisor_vendor: String.t() | nil,
          firewall_ok: boolean()
        }

  @type spec :: %{
          vm_id: String.t(),
          vcpus: pos_integer(),
          memory_mib: pos_integer(),
          disk_gib: pos_integer(),
          limits: map(),
          image: map(),
          clone: Path.t(),
          boot_args: String.t(),
          net: map(),
          guest_socket: Path.t() | nil,
          guest_token: String.t(),
          guest_api: String.t(),
          deadline: integer(),
          console_log: Path.t(),
          vm_dir: Path.t()
        }

  @callback capabilities() :: {:ok, capabilities} | {:error, term}
  @callback prepare_image(map()) :: {:ok, map()} | {:error, term}
  @callback start(spec) :: :ok | {:error, term}
  @callback stop(vm_id :: String.t(), force :: boolean) :: :ok | {:error, term}
  @callback alive?(vm_id :: String.t()) :: boolean
  @callback list() :: {:ok, [String.t()]}
  @callback stats(vm_id :: String.t()) ::
              {:ok, %{cpu_pct: float, rss_mib: integer}} | {:error, term}
  @doc "Idempotent; safe if never started."
  @callback cleanup(vm_id :: String.t()) :: :ok
  @doc "How the VM ended, once it's not alive: `{:ok, %{code: integer, reason: atom | nil}}`."
  @callback exit_status(vm_id :: String.t()) :: {:ok, map()} | :unknown
  @doc "Free MiB in the VM area, for a driver whose VMs don't use the host's disk."
  @callback vm_area_free_mib() :: non_neg_integer
  @optional_callbacks vm_area_free_mib: 0

  @doc "The configured driver module."
  def impl, do: CrewAgent.Config.driver_module(CrewAgent.Config.get())
end
