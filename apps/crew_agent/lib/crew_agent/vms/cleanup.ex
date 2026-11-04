defmodule CrewAgent.VMs.Cleanup do
  @moduledoc """
  A VM's cleanup that didn't finish (`driver.cleanup/1` failed: crew-vmctl
  away, a jail that wouldn't go) isn't forgotten:

  - `vms/<vm_id>/cleanup-pending` records it, and `vm.exited` says
    `cleanup: "error"`;
  - the VM keeps its lease (another VM would get its tap) and its clone
    (the jail's hard link keeps the space allocated anyway, and the disk
    watchdog sees it), and its directory isn't swept;
  - `retry_all/0` tries again, at agent start and every minute
    (`CrewAgent.VMs.Janitor`), until it works.

  At start, `reconcile/0` also cleans up what the driver still holds for
  VMs the agent has no live or pending record of: a jail left by a VM
  whose directory has gone, say.
  """

  require Logger

  alias CrewAgent.{Config, Driver, Net, SafeFS}

  @marker "cleanup-pending"

  def pending?(config \\ Config.get(), vm_id),
    do: File.exists?(Path.join(Config.vm_dir(config, vm_id), @marker))

  @doc "The VMs with a cleanup to finish."
  def pending_ids(config \\ Config.get()) do
    case File.ls(Config.vms_dir(config)) do
      {:ok, names} -> Enum.filter(names, &(CrewProtocol.uuid?(&1) and pending?(config, &1)))
      _ -> []
    end
  end

  @doc "A cleanup that worked: the lease and the clone go, and the record."
  def done(config \\ Config.get(), vm_id) do
    dir = Config.vm_dir(config, vm_id)
    Net.release(vm_id)
    File.rm(Path.join(dir, "rootfs.ext4"))
    File.rm(Path.join(dir, @marker))
    :ok
  end

  @doc "A cleanup that didn't: recorded, with why, for `retry_all/0`."
  def failed(config \\ Config.get(), vm_id, why) do
    dir = Config.vm_dir(config, vm_id)
    Logger.error("cleaning up VM #{vm_id} failed, and will be retried: #{why}")

    body =
      Jason.encode!(%{
        "error" => why |> to_string() |> String.slice(0, 1024),
        "at" => System.os_time(:millisecond)
      })

    if File.dir?(dir), do: SafeFS.write_atomic(Path.join(dir, @marker), body, 0o640), else: :ok
  end

  @doc """
  At start, before anything can start: each pending VM takes its lease
  back, so no new VM is given a tap that may still be there.
  """
  def claim_leases(config \\ Config.get()) do
    for vm_id <- pending_ids(config), index = lease_index(config, vm_id), is_integer(index) do
      case Net.claim(vm_id, index) do
        {:ok, _} -> :ok
        {:error, why} -> Logger.error("VM #{vm_id}'s lease #{index}: #{inspect(why)}")
      end
    end

    :ok
  end

  @doc """
  Tries each pending cleanup again. A marker is only written once a VM
  has ended, so none of them is running.
  """
  def retry_all(config \\ Config.get()) do
    driver = Driver.impl()

    for vm_id <- pending_ids(config) do
      case driver.cleanup(vm_id) do
        :ok ->
          Logger.info("VM #{vm_id}'s cleanup finished on a retry")
          done(config, vm_id)

        {:error, why} ->
          failed(config, vm_id, inspect_why(why))
      end
    end

    :ok
  end

  @doc """
  At start: cleans up what the driver holds (units, jails) for VMs that
  the agent has neither live (adoption's) nor pending (`retry_all/0`'s).
  """
  def reconcile(config \\ Config.get()) do
    driver = Driver.impl()

    with true <- Code.ensure_loaded?(driver) and function_exported?(driver, :leftovers, 0),
         {:ok, ids} <- driver.leftovers() do
      for vm_id <- ids, CrewProtocol.uuid?(vm_id), not held?(config, vm_id) do
        Logger.warning("VM #{vm_id} has a jail or unit and no record here: cleaning it up")

        case driver.cleanup(vm_id) do
          :ok -> :ok
          {:error, why} -> failed(config, vm_id, inspect_why(why))
        end
      end
    end

    :ok
  end

  # Live (it has a vm.json and hasn't exited: adoption has it) or pending.
  defp held?(config, vm_id) do
    dir = Config.vm_dir(config, vm_id)

    pending?(config, vm_id) or
      (File.exists?(Path.join(dir, "vm.json")) and not File.exists?(Path.join(dir, "exited.json")))
  end

  defp lease_index(config, vm_id) do
    with {:ok, body} <- File.read(Path.join(Config.vm_dir(config, vm_id), "vm.json")),
         {:ok, %{"lease_index" => index}} <- Jason.decode(body),
         do: index,
         else: (_ -> nil)
  end

  defp inspect_why(why) when is_binary(why), do: why
  defp inspect_why(why), do: inspect(why)
end
