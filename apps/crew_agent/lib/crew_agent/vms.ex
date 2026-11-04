defmodule CrewAgent.VMs do
  @moduledoc """
  This box's job VMs: a DynamicSupervisor of `CrewAgent.VM` servers, and
  what commands and reports need from them (§10.3, §10.6, §10.7).
  """

  require Logger

  alias CrewAgent.{Config, Driver, VM}
  alias CrewAgent.VMs.Cleanup

  @sup CrewAgent.VMs.Supervisor

  def child_spec(_),
    do: %{
      id: @sup,
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: @sup]]},
      type: :supervisor
    }

  @doc """
  `vm.start`, idempotent by `vm_id` (§10.3): a VM whose directory exists
  answers ok if it's alive, and `duplicate` if not.
  """
  def start(cmd) do
    vm_id = cmd.payload.vm_id
    dir = Config.vm_dir(Config.get(), vm_id)

    if File.exists?(dir) do
      if VM.whereis(vm_id) || Driver.impl().alive?(vm_id),
        do: :ok,
        else: {:error, "duplicate", "VM #{vm_id} was started before"}
    else
      case DynamicSupervisor.start_child(@sup, {VM, {:start, cmd, nil}}) do
        {:ok, _pid} ->
          :ok

        {:error, {:start_failed, :image_not_ready}} ->
          {:error, "image_not_ready", "the image isn't ready on this box"}

        {:error, {:start_failed, reason}} ->
          {:error, "start_failed", to_string(reason)}

        {:error, :duplicate} ->
          {:error, "duplicate", "VM #{vm_id} was started before"}

        {:error, reason} ->
          {:error, "start_failed", inspect(reason)}
      end
    end
  end

  @doc "`vm.stop`: graceful through the guest, or force."
  def stop(vm_id, force, grace_s) do
    case VM.call(vm_id, {:stop, force, grace_s}) do
      :ok ->
        :ok

      {:error, :no_vm} ->
        # No server (it ended, or adoption failed) but the driver may
        # still have it: a forced stop always goes through.
        driver = Driver.impl()
        if driver.alive?(vm_id), do: driver.stop(vm_id, true), else: :ok
    end
  end

  @doc """
  Kills a VM now, recording why in its `vm.exited` detail. A VM the
  agent holds no server for, but the driver has, is killed through the
  driver.
  """
  def kill(vm_id, detail) do
    case VM.call(vm_id, {:kill, detail}) do
      :ok -> :ok
      {:error, :no_vm} -> Driver.impl().stop(vm_id, true)
    end
  end

  @doc "The VMs this agent holds that haven't exited."
  def running_ids, do: Enum.filter(vm_ids(), &(VM.whereis(&1) != nil and not exited?(&1)))

  def log_ack(vm_id, epoch, seq) do
    case VM.call(vm_id, {:log_ack, epoch, seq}) do
      {:error, :no_vm} -> :ok
      other -> other
    end
  end

  @doc "A resend for a VM the agent no longer holds: those lines are gone (§16.2)."
  def log_resend(vm_id, epoch, from_seq) do
    case VM.call(vm_id, {:log_resend, epoch, from_seq}) do
      {:error, :no_vm} ->
        {:ok, event} =
          CrewProtocol.Event.new("vm.log.gone", %{vm_id: vm_id, epoch: epoch, up_to_seq: from_seq})

        CrewAgent.Outbox.push(event)
        :ok

      other ->
        other
    end
  end

  @doc """
  Adoption on agent start (§10.7), before joining: every VM directory
  without `exited.json` gets its server back.
  """
  def adopt_all do
    for vm_id <- vm_ids(), not exited?(vm_id), is_nil(VM.whereis(vm_id)) do
      case DynamicSupervisor.start_child(@sup, {VM, {:adopt, vm_id}}) do
        {:ok, _} -> :ok
        :ignore -> :ok
        {:error, reason} -> Logger.error("adopting #{vm_id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "A (re)connect: each VM sends its unacknowledged log batches again."
  def connected do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@sup),
        is_pid(pid),
        do: GenServer.cast(pid, :resend_unacked)

    :ok
  end

  @doc "VMs whose VMM is running: a VM that exited keeps its server while its logs drain."
  def running_count, do: length(running_ids())

  # box.inventory carries at most this many VMs (CrewProtocol.Event).
  @inventory_max 1000

  @doc "`box.inventory`'s VMs: every live one, then the most recently exited, within the protocol's bound."
  def inventory do
    {live, exited} =
      vm_ids()
      |> Enum.map(&inventory_entry/1)
      |> Enum.split_with(& &1.alive)

    exited = Enum.sort_by(exited, &((&1.exited && &1.exited.at) || 0), :desc)
    Enum.take(live ++ exited, @inventory_max)
  end

  defp inventory_entry(vm_id) do
    exited = read_json(vm_id, "exited.json")
    meta = read_json(vm_id, "vm.json") || %{}

    %{
      vm_id: vm_id,
      alive: is_nil(exited) and (VM.whereis(vm_id) != nil or Driver.impl().alive?(vm_id)),
      since: meta["created_at"],
      exited:
        exited &&
          %{reason: exited["reason"], exit_status: exited["code"] || 0, at: exited["at"] || 0}
    }
  end

  defp vm_ids do
    case File.ls(Config.vms_dir(Config.get())) do
      {:ok, names} -> Enum.filter(names, &CrewProtocol.uuid?/1)
      _ -> []
    end
  end

  defp exited?(vm_id),
    do: File.exists?(Path.join(Config.vm_dir(Config.get(), vm_id), "exited.json"))

  defp read_json(vm_id, name) do
    with {:ok, body} <- File.read(Path.join(Config.vm_dir(Config.get(), vm_id), name)),
         {:ok, map} <- Jason.decode(body),
         do: map,
         else: (_ -> nil)
  end

  @doc "Removes the directories of VMs that exited over an hour ago."
  def sweep_exited(max_age_ms \\ 3_600_000) do
    now = System.os_time(:millisecond)

    # A VM whose cleanup is still to finish keeps its record (and lease).
    for vm_id <- vm_ids(),
        not Cleanup.pending?(vm_id),
        exited = read_json(vm_id, "exited.json"),
        now - (exited["at"] || now) > max_age_ms do
      File.rm_rf(Config.vm_dir(Config.get(), vm_id))
    end

    :ok
  end
end
