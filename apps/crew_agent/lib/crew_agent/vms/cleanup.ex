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

  @doc "A cleanup that worked: the lease, the clone and its kernel go, and the record."
  def done(config \\ Config.get(), vm_id) do
    dir = Config.vm_dir(config, vm_id)
    Net.release(vm_id)
    File.rm(Path.join(dir, "rootfs.ext4"))
    File.rm(Path.join(dir, "kernel"))
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

  @conflicts {__MODULE__, :conflicts}
  @orphans {__MODULE__, :orphans}

  @doc """
  Holds the lease of every VM the agent has a record of that isn't done
  with it: live (its server or adoption has it) or with a cleanup
  pending. The janitor does this synchronously as the agent starts,
  before the link (and so any `vm.start`) is up, and again each minute.

  Two records holding one lease is a conflict, kept with the orphans'
  (`reconcile/0`) in `conflicts/0`, and no VM starts while there are any
  (`CrewAgent.VMs.start/1`).
  """
  def reserve_leases(config \\ Config.get()) do
    found =
      for vm_id <- vm_ids(config),
          held?(config, vm_id),
          index = lease_index(config, vm_id),
          is_integer(index),
          not claim(vm_id, index),
          do: {vm_id, index}

    put_conflicts(found)
    if found == [], do: :ok, else: {:error, found}
  end

  @doc "Leases two records (or a record and an orphan jail) hold: `[{vm_id, index}]`."
  def conflicts, do: :persistent_term.get(@conflicts, [])

  defp put_conflicts(found) do
    if found != [] and found != conflicts() do
      Logger.error("leases held twice, so no VM starts until it's sorted out: #{inspect(found)}")
    end

    :persistent_term.put(@conflicts, found)
  end

  defp claim(vm_id, index), do: match?({:ok, _}, Net.claim(vm_id, index))

  defp vm_ids(config) do
    case File.ls(Config.vms_dir(config)) do
      {:ok, names} -> Enum.filter(names, &CrewProtocol.uuid?/1)
      _ -> []
    end
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
  Cleans up what the driver holds (units, jails) for VMs the agent has
  neither live (adoption's) nor pending (`retry_all/0`'s): at start and
  every minute, so an orphan whose cleanup fails, or a `list` that
  fails, is tried again. Until its cleanup works an orphan holds the
  lease its jail recorded, so no new VM is given its tap. The jail is
  the record of the work; nothing needs writing here.
  """
  def reconcile(config \\ Config.get()) do
    driver = Driver.impl()

    with true <- Code.ensure_loaded?(driver) and function_exported?(driver, :leftovers, 0),
         {:ok, leftovers} <- driver.leftovers() do
      orphans =
        for {vm_id, index} <- leftovers, CrewProtocol.uuid?(vm_id), not held?(config, vm_id) do
          {vm_id, index}
        end

      clashes =
        for {id, index} <- orphans, is_integer(index), not claim(id, index), do: {id, index}

      put_conflicts(Enum.uniq(conflicts() ++ clashes))

      # Orphans held before and gone now (their jail went some other way)
      # give their leases back too.
      held = MapSet.new(for {id, i} <- orphans, is_integer(i), do: id)
      for id <- held_orphans(), not MapSet.member?(held, id), do: Net.release(id)
      :persistent_term.put(@orphans, held)

      for {vm_id, index} <- orphans, do: clean_orphan(config, driver, vm_id, index)
    end

    :ok
  end

  defp held_orphans, do: :persistent_term.get(@orphans, MapSet.new())

  @doc false
  def reset do
    :persistent_term.erase(@conflicts)
    :persistent_term.erase(@orphans)
  end

  defp clean_orphan(config, driver, vm_id, index) do
    Logger.warning("VM #{vm_id} has a jail or unit and no record here: cleaning it up")

    case driver.cleanup(vm_id) do
      :ok ->
        # Its lease, if it held one, is free now.
        if is_integer(index), do: Net.release(vm_id)
        :persistent_term.put(@orphans, MapSet.delete(held_orphans(), vm_id))
        put_conflicts(Enum.reject(conflicts(), &(elem(&1, 0) == vm_id)))

      {:error, why} ->
        # A VM with a directory here gets a pending record (and with it
        # its lease); one without is found again by its jail next time.
        failed(config, vm_id, inspect_why(why))
    end
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
