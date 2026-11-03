defmodule CrewProtocol.Names do
  @moduledoc """
  Box names, deployment ids and runner names (§6.3).

  A runner is named `crew-<deployment id>-<box name>-<vm suffix>`. The
  suffix is the last 10 hex characters of the VM's UUID (its random bits),
  and box names are DNS labels of at most 40 characters, so a runner name
  is at most 61 characters.
  """

  @box ~r/\A[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?\z/
  @deployment ~r/\A[a-z0-9]{4}\z/
  @runner ~r/\Acrew-([a-z0-9]{4})-([a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?)-([0-9a-f]{10})\z/
  @alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  def box_name?(name) when is_binary(name), do: Regex.match?(@box, name)
  def box_name?(_), do: false

  def deployment_id?(id) when is_binary(id), do: Regex.match?(@deployment, id)
  def deployment_id?(_), do: false

  @doc "A fresh random deployment id."
  def new_deployment_id do
    for <<b <- :crypto.strong_rand_bytes(4)>>, into: "" do
      <<Enum.at(@alphabet, rem(b, length(@alphabet)))>>
    end
  end

  @doc "The last 10 hex characters of a VM's UUID."
  def vm_suffix(vm_id) when is_binary(vm_id) do
    hex = String.replace(vm_id, "-", "")
    binary_part(hex, byte_size(hex) - 10, 10)
  end

  def runner_name(deployment_id, box_name, vm_id),
    do: "crew-#{deployment_id}-#{box_name}-#{vm_suffix(vm_id)}"

  def parse_runner_name(name) when is_binary(name) and byte_size(name) <= 61 do
    case Regex.run(@runner, name) do
      [_, deployment, box, suffix] ->
        {:ok, %{deployment_id: deployment, box: box, suffix: suffix}}

      nil ->
        :error
    end
  end

  def parse_runner_name(_), do: :error

  @doc "Whether `runner_name` is a runner of this deployment."
  def ours?(runner_name, deployment_id) do
    match?({:ok, %{deployment_id: ^deployment_id}}, parse_runner_name(runner_name))
  end
end
