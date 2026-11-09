defmodule CrewProtocol.Sizes do
  @moduledoc """
  The rules for named sizes (§7.1), shared by the control plane's Sizes
  page and the `vm.start` validation on the agent.
  """

  @name ~r/\A[a-z0-9](?:[a-z0-9-]{0,10}[a-z0-9])?\z/

  @defaults [
    %{name: "xs", vcpus: 1, memory_mib: 2048, disk_gib: 20, is_default: false},
    %{name: "s", vcpus: 2, memory_mib: 4096, disk_gib: 40, is_default: false},
    %{name: "m", vcpus: 4, memory_mib: 8192, disk_gib: 60, is_default: true},
    %{name: "l", vcpus: 8, memory_mib: 16_384, disk_gib: 100, is_default: false},
    %{name: "xl", vcpus: 16, memory_mib: 32_768, disk_gib: 150, is_default: false}
  ]

  @doc "The sizes a new deployment starts with."
  def defaults, do: @defaults

  @doc "Validates a size's name, vcpus, memory and disk. Every problem is reported."
  @spec validate(map()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate(size) do
    [
      name: name_error(size[:name]),
      vcpus: vcpus_error(size[:vcpus]),
      memory_mib: memory_error(size[:memory_mib]),
      disk_gib: disk_error(size[:disk_gib])
    ]
    |> Enum.reject(fn {_, e} -> is_nil(e) end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc "The checks on a VM's size in `vm.start` (name aside)."
  def check_vm_size(size) do
    [
      vcpus: vcpus_error(size[:vcpus]),
      memory_mib: memory_error(size[:memory_mib]),
      disk_gib: disk_error(size[:disk_gib])
    ]
    |> Enum.reject(fn {_, e} -> is_nil(e) end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def name_error(name) when is_binary(name) do
    cond do
      not Regex.match?(@name, name) -> "must be a lowercase DNS label of 1 to 12 characters"
      name in ["x64", "arm64"] -> "can't be an arch"
      String.ends_with?(name, ["-x64", "-arm64"]) -> "can't end in an arch"
      name == "spare" -> "can't be spare"
      String.ends_with?(name, "-spare") -> "can't end in -spare"
      String.contains?(name, "crew") -> "can't contain crew"
      true -> nil
    end
  end

  def name_error(_), do: "must be a lowercase DNS label of 1 to 12 characters"

  def vcpus_error(v) when v === 1 or (is_integer(v) and v in 2..32//2), do: nil
  def vcpus_error(_), do: "must be 1 or an even number up to 32"

  def memory_error(v) when is_integer(v) and v >= 1024 and rem(v, 256) == 0, do: nil
  def memory_error(_), do: "must be at least 1024 and a multiple of 256"

  def disk_error(v) when is_integer(v) and v in 10..2000, do: nil
  def disk_error(_), do: "must be 10 to 2000"
end
