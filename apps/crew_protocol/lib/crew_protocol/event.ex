defmodule CrewProtocol.Event do
  @moduledoc """
  An event an agent sends to the control plane (§10.4).

  Every string has a stated maximum, and out-of-range values are refused,
  not clamped. Timestamps are the exception: the control plane clamps them
  to the VM's lifetime when it stores them. Times are Unix milliseconds
  (`at`, `t` on VM events) unless a field says seconds.
  """

  alias CrewProtocol.Schema

  @enforce_keys [:type, :payload]
  defstruct [:type, :payload]

  @type t :: %__MODULE__{type: String.t(), payload: map()}

  @vm_states ~w(booted runner_listening job_started job_finished job_refused)
  @exit_reasons ~w(poweroff crashed killed_deadline killed_stop killed_disk boot_failed)
  @image_states ~w(downloading verifying converting ready failed)
  @step_statuses ~w(pending queued in_progress completed)
  @step_conclusions ~w(success failure cancelled skipped neutral)

  # A vm.log message carries at most this much text.
  @max_log_message 262_144

  @line {:object,
         n: {:integer, required: true},
         t: {:integer, required: true},
         step_ref: {:step_ref, []},
         text: {:text, required: true, max: 65_536},
         truncated: {:boolean, default: false}}

  @step {:object,
         ref: {:step_ref, required: true},
         name: {:string, required: true, max: 512},
         number: {:integer, required: true, max: 10_000},
         status: {{:enum, @step_statuses}, required: true},
         started_at: {:integer, []},
         completed_at: {:integer, []},
         conclusion: {{:enum, @step_conclusions}, []}}

  @specs %{
    "op.result" => [
      op_id: {:uuid, required: true},
      status: {{:enum, ["ok", "error"]}, required: true},
      result: {:json, default: %{}},
      error:
        {{:object, code: {:code, required: true}, message: {:text, required: true, max: 2048}},
         []}
    ],
    "vm.state" => [
      vm_id: {:uuid, required: true},
      state: {{:enum, @vm_states}, required: true},
      at: {:integer, required: true},
      detail: {:text, max: 1024}
    ],
    "vm.exited" => [
      vm_id: {:uuid, required: true},
      reason: {{:enum, @exit_reasons}, required: true},
      exit_status: {:int, default: 0},
      uptime_ms: {:integer, default: 0},
      cleanup: {{:enum, ["ok", "error"]}, required: true},
      detail: {:text, max: 1024}
    ],
    "vm.log" => [
      vm_id: {:uuid, required: true},
      epoch: {:hex16, required: true},
      seq: {:integer, required: true},
      lines: {{:list, @line}, required: true, max: 10_000, check: &__MODULE__.log_message_size/1}
    ],
    "vm.log.gone" => [
      vm_id: {:uuid, required: true},
      epoch: {:hex16, required: true},
      up_to_seq: {:integer, required: true}
    ],
    "vm.steps" => [
      vm_id: {:uuid, required: true},
      steps: {{:list, @step}, required: true, max: 1000}
    ],
    "vm.metrics" => [
      vm_id: {:uuid, required: true},
      t: {:integer, required: true},
      cpu_pct: {:number, default: 0, max: 100.0},
      mem_used_mib: {:integer, default: 0},
      mem_total_mib: {:integer, default: 0},
      disk_used_mib: {:integer, default: 0},
      net_rx_bps: {:number, default: 0},
      net_tx_bps: {:number, default: 0},
      host_cpu_pct: {:number, default: 0, max: 100_000.0},
      host_rss_mib: {:integer, default: 0}
    ],
    "box.metrics" => [
      t: {:integer, required: true},
      cpu_pct: {:number, required: true, max: 100.0},
      mem_used_mib: {:integer, required: true},
      mem_total_mib: {:integer, required: true},
      swap_used_mib: {:integer, default: 0},
      load1: {:number, default: 0},
      disk_used_mib: {:integer, required: true},
      disk_total_mib: {:integer, required: true},
      vm_area_free_mib: {:integer, required: true},
      cache_used_mib: {:integer, default: 0},
      vms_running: {:integer, default: 0}
    ],
    "box.capabilities" => [
      driver: {{:enum, ~w(firecracker vz null)}, required: true},
      driver_version: {:string, required: true, max: 64},
      guest_arch: {{:enum, ~w(x64 arm64)}, required: true},
      vcpus: {:integer, required: true, min: 1, max: 4096},
      memory_mib: {:integer, required: true, min: 1},
      vm_area_mib: {:integer, required: true},
      max_vcpus_per_vm: {:integer, required: true, min: 1, max: 4096},
      max_memory_mib_per_vm: {:integer, required: true, min: 1},
      vmm_overhead_mib: {:integer, required: true},
      features: {{:list, :code}, default: [], max: 32},
      virtualized: {:boolean, required: true},
      hypervisor_vendor: {:string, max: 64},
      firewall_ok: {:boolean, required: true},
      sleep_disabled: {:boolean, []}
    ],
    "box.inventory" => [
      vms:
        {{:list,
          {:object,
           vm_id: {:uuid, required: true},
           alive: {:boolean, required: true},
           since: {:integer, []},
           exited:
             {{:object,
               reason: {{:enum, @exit_reasons}, required: true},
               exit_status: {:int, default: 0},
               at: {:integer, required: true}}, []}}}, required: true, max: 1000},
      images:
        {{:list,
          {:object, id: {:uuid, required: true}, state: {{:enum, @image_states}, required: true}}},
         required: true, max: 100}
    ],
    "box.reboot" => [
      required: {:boolean, required: true},
      packages: {{:list, :string}, default: [], max: 50},
      boot_id: {:uuid, required: true},
      can_restart: {:boolean, default: false},
      os_version: {:string, max: 128},
      cache_vm:
        {{:object,
          required: {:boolean, required: true},
          packages: {{:list, :string}, default: [], max: 50},
          boot_id: {:uuid, required: true}}, []}
    ],
    "image.state" => [
      image_id: {:uuid, required: true},
      state: {{:enum, @image_states}, required: true},
      progress: {:integer, default: 0, max: 100},
      error: {:text, max: 1024}
    ],
    "cache.stats" => [
      t: {:integer, required: true},
      hosts:
        {{:list,
          {:object,
           host: {{:enum, CrewProtocol.Hosts.names()}, required: true},
           hits: {:integer, default: 0},
           misses: {:integer, default: 0},
           bytes_served: {:integer, default: 0},
           bytes_stored: {:integer, default: 0}}}, default: [], max: 32},
      # The repositories served most, for the Caches page's top images.
      top:
        {{:list,
          {:object,
           host: {{:enum, CrewProtocol.Hosts.names()}, required: true},
           repo: {:string, required: true, max: 255},
           hits: {:integer, default: 0},
           bytes_served: {:integer, default: 0}}}, default: [], max: 10},
      evictions: {:integer, default: 0},
      digest_mismatches: {:integer, default: 0}
    ]
  }

  def types, do: Map.keys(@specs)
  def vm_states, do: @vm_states
  def exit_reasons, do: @exit_reasons
  def image_states, do: @image_states
  def max_log_message, do: @max_log_message

  @spec new(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def new(type, payload) do
    case Map.fetch(@specs, type) do
      {:ok, spec} ->
        with {:ok, payload} <- Schema.cast(payload, spec),
             :ok <- check(type, payload) do
          {:ok, %__MODULE__{type: type, payload: payload}}
        end

      :error ->
        {:error, {:unknown_type, type}}
    end
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{type: type, payload: payload}) do
    %{"type" => type, "payload" => Schema.dump(payload, Map.fetch!(@specs, type))}
  end

  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{"type" => type, "payload" => payload}) when is_binary(type),
    do: new(type, payload)

  def from_wire(_), do: {:error, :malformed}

  # Checks across fields, after each field is valid on its own.
  defp check("op.result", %{status: "error"} = payload) when not is_map_key(payload, :error),
    do: {:error, [{"error", "is required"}]}

  defp check(_type, _payload), do: :ok

  @doc false
  # On the encoded message, since JSON escaping can widen text six-fold.
  # The text alone is checked first, so an oversized batch isn't encoded.
  def log_message_size(lines) do
    cond do
      Enum.reduce(lines, 0, &(byte_size(&1.text) + &2)) > @max_log_message ->
        {:error, "is over 256 KiB"}

      lines |> Jason.encode_to_iodata!() |> IO.iodata_length() > @max_log_message ->
        {:error, "is over 256 KiB"}

      true ->
        :ok
    end
  end
end
