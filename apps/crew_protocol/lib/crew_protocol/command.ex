defmodule CrewProtocol.Command do
  @moduledoc """
  A command the control plane sends to an agent (§10.3).

  The vocabulary is fixed (see `types/0`). There's no generic `exec`:
  every command maps to one code path on the agent, and every payload is
  validated against its spec on both sides of the socket.

  `vm.start` carries the VM's JIT runner config, which is a credential.
  `Inspect` never shows it, and `redact/1` removes it (and the parent
  cache's token) from anything about to be stored or logged.
  """

  alias CrewProtocol.{Hosts, Schema, Sizes}

  @enforce_keys [:op_id, :type, :payload]
  defstruct [:op_id, :type, :payload]

  @type t :: %__MODULE__{op_id: String.t(), type: String.t(), payload: map()}

  @arches ~w(x64 arm64)

  @stop_reasons ~w(reaped timeout finished deadline admin refused revoked drain
                   cancelled lost duplicate)

  # An agent or cache release tarball is tens of MiB; this only bounds it.
  @max_tarball 2_147_483_648

  @file_ref {:object,
             url: {:url, required: true, max: 2048},
             sha256: {:sha256, required: true},
             size: {:integer, required: true}}

  @specs %{
    "vm.start" => [
      vm_id: {:uuid, required: true},
      name: {:runner_name, required: true},
      size:
        {{:object,
          vcpus: {:integer, required: true},
          memory_mib: {:integer, required: true},
          disk_gib: {:integer, required: true},
          limits:
            {{:object,
              disk_iops: {:integer, max: 1_000_000},
              disk_bandwidth_mbps: {:integer, max: 100_000},
              net_bandwidth_mbps: {:integer, max: 100_000}}, default: %{}}},
         required: true, check: &Sizes.check_vm_size/1},
      image:
        {{:object,
          id: {:uuid, required: true},
          version: {:version, required: true},
          arch: {{:enum, @arches}, required: true},
          manifest_sha256: {:sha256, required: true}}, required: true},
      jit_config: {:base64, required: true, max: 16_384},
      labels: {{:list, :label}, required: true, min: 1, max: 10},
      deadline: {:integer, required: true},
      log_limit_bytes: {:integer, required: true, max: 10_737_418_240},
      policy:
        {{:object,
          fork_prs: {{:enum, ~w(refuse allow)}, required: true},
          repo_full_name: {:repo, required: true}}, required: true}
    ],
    "vm.stop" => [
      vm_id: {:uuid, required: true},
      reason: {{:enum, @stop_reasons}, required: true},
      force: {:boolean, default: false},
      grace_s: {:integer, default: 30, max: 300}
    ],
    "vm.log.ack" => [
      vm_id: {:uuid, required: true},
      epoch: {:hex16, required: true},
      seq: {:integer, required: true}
    ],
    "vm.log.resend" => [
      vm_id: {:uuid, required: true},
      epoch: {:hex16, required: true},
      from_seq: {:integer, required: true}
    ],
    "image.prepare" => [
      image:
        {{:object,
          id: {:uuid, required: true},
          version: {:version, required: true},
          arch: {{:enum, @arches}, required: true},
          kernel: {@file_ref, required: true},
          rootfs: {@file_ref, required: true},
          manifest: {:base64, required: true, max: 65_536},
          signature: {:base64, required: true, max: 128}}, required: true}
    ],
    "image.remove" => [image_id: {:uuid, required: true}],
    "cache.config" => [
      enabled_hosts: {{:list, {:enum, Hosts.names()}}, required: true},
      allowlist: {{:list, :string}, required: true, max: 500, check: &__MODULE__.allowlist/1},
      parent:
        {{:object,
          url: {:https_url, required: true, max: 512},
          token: {:string, required: true, max: 256},
          ca_pem: {:pem, required: true, max: 16_384}}, []},
      rotate_ca: {:boolean, default: false}
    ],
    "cache.purge" => [scope: {:string, required: true, max: 512, check: &__MODULE__.scope/1}],
    "box.inventory" => [],
    "box.restart" => [boot_id: {:uuid, required: true}, force: {:boolean, default: false}],
    "cachevm.restart" => [boot_id: {:uuid, required: true}],
    # §20.2: the agent's tarball for the box's target, and on Linux
    # crew_cache's at the same version. Each signature is
    # `CrewProtocol.Auth.sign_release/4`'s, over the version, the agent's
    # own target and the tarball's SHA-256; the agent checks it before it
    # downloads anything.
    "agent.update" => [
      version: {:version, required: true},
      url: {:url, required: true, max: 2048},
      sha256: {:sha256, required: true},
      size: {:integer, required: true, min: 1, max: @max_tarball},
      signature: {:base64, required: true, max: 128},
      cache:
        {{:object,
          url: {:url, required: true, max: 2048},
          sha256: {:sha256, required: true},
          size: {:integer, required: true, min: 1, max: @max_tarball},
          signature: {:base64, required: true, max: 128}}, []}
    ],
    "op.cancel" => [target_op_id: {:uuid, required: true}]
  }

  # Keys that never leave memory: not in operation rows, logs or telemetry.
  @secret_keys ["jit_config", "token"]

  @doc "All command types."
  def types, do: Map.keys(@specs)

  @doc "The payload spec for a command type."
  def spec(type), do: Map.fetch!(@specs, type)

  def stop_reasons, do: @stop_reasons

  @spec new(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(type, payload, opts \\ []) do
    with {:ok, spec} <- fetch_spec(type),
         {:ok, payload} <- Schema.cast(payload, spec) do
      {:ok,
       %__MODULE__{
         op_id: Keyword.get_lazy(opts, :op_id, &CrewProtocol.uuid/0),
         type: type,
         payload: payload
       }}
    end
  end

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = cmd) do
    %{
      "op_id" => cmd.op_id,
      "type" => cmd.type,
      "payload" => Schema.dump(cmd.payload, spec(cmd.type))
    }
  end

  @spec from_wire(term()) :: {:ok, t()} | {:error, term()}
  def from_wire(%{"op_id" => op_id, "type" => type, "payload" => payload})
      when is_binary(op_id) do
    with {:ok, _} <- Schema.cast(%{"op_id" => op_id}, op_id: {:uuid, required: true}) do
      new(type, payload, op_id: op_id)
    end
  end

  def from_wire(_), do: {:error, :malformed}

  defp fetch_spec(type) do
    case Map.fetch(@specs, type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_type, type}}
    end
  end

  @doc """
  Removes secret keys (the JIT config, tokens) from a map, at any depth.
  For anything that's about to be stored, logged or sent to telemetry.
  """
  def redact(%_{} = struct), do: struct

  def redact(map) when is_map(map) do
    for {k, v} <- map, to_string(k) not in @secret_keys, into: %{}, do: {k, redact(v)}
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(other), do: other

  @doc false
  def secret_keys, do: @secret_keys

  @doc false
  def allowlist(entries) do
    case Enum.reject(entries, &Hosts.allowlist_entry?/1) do
      [] -> :ok
      [bad | _] -> {:error, "#{bad} isn't <known host>/<repository glob>"}
    end
  end

  @doc false
  def scope("all"), do: :ok

  def scope("host:" <> host) do
    if host in Hosts.names(), do: :ok, else: {:error, "names a host Crew doesn't know"}
  end

  def scope("repo:" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [host, path] when path != "" ->
        cond do
          host not in Hosts.names() -> {:error, "names a host Crew doesn't know"}
          not Regex.match?(~r/\A[a-z0-9._\/-]+\z/, path) -> {:error, "has a bad repository"}
          String.contains?(path, ["..", "//"]) -> {:error, "has a bad repository"}
          true -> :ok
        end

      _ ->
        {:error, "must be repo:<host>/<repository>"}
    end
  end

  def scope(_), do: {:error, "must be all, host:<host> or repo:<host>/<repository>"}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(cmd, opts) do
      payload = mask(cmd.payload)

      concat([
        "#CrewProtocol.Command<",
        to_doc(cmd.type, opts),
        " ",
        to_doc(cmd.op_id, opts),
        " ",
        to_doc(payload, opts),
        ">"
      ])
    end

    defp mask(map) when is_map(map) do
      Map.new(map, fn {k, v} ->
        if to_string(k) in CrewProtocol.Command.secret_keys(),
          do: {k, :redacted},
          else: {k, mask(v)}
      end)
    end

    defp mask(other), do: other
  end
end
