defmodule Crew.Boxes.Reboots do
  @moduledoc """
  Reboots, always started by an admin (§12.1):

  - **A Flatcar box** (`:box`): the box drains (no new placements; idle
    runners are reaped and busy jobs finish, §8.5). Once it has no VM
    left, `box.restart` goes with the boot ID last seen, and the agent
    has crew-vmctl reboot it. Its rejoin on a new boot ends the reboot.
  - **A `mac-vz` box's cache VM** (`:cache_vm`): the box drains the same
    way, then `cachevm.restart` goes with the cache VM's boot ID, and the
    agent asks launchd to restart it. A `box.reboot` whose `cache_vm` is
    on a new boot ends it.
  - **Reboot now** (`now: true`, a box only) stops the box's VMs by force
    and reboots at once; it's audit-logged with the jobs it cut short.

  The end lifts the drain only if the reboot set it. A resent command
  after the reboot finds another boot and does nothing (the agent
  answers `already`), so `advance/1` can send it again freely: on the
  request, on each inventory, on each VM gone and on each rejoin.

  A box rebooted for a Flatcar update keeps the version it had in
  `previous_os_version` until it reports a new one; still on the old one
  after the reboot means Flatcar's GRUB fell back (`rolled_back?/1`).
  """

  import Ecto.Query

  alias Crew.{Activity, Audit, Boxes, Operations, Repo, Scope, VMs}
  alias Crew.Boxes.Box

  @doc "Starts a reboot of `target` (`:box` or `:cache_vm`)."
  def request(%Scope{} = scope, %Box{} = box, target, opts \\ []) do
    now? = Keyword.get(opts, :now, false)

    with true <- Scope.admin?(scope) || {:error, :unauthorized},
         {:ok, boot_id} <- target_boot(box, target) do
      draining? = box.draining

      box =
        box
        |> Ecto.Changeset.change(
          reboot_requested_at: DateTime.utc_now(),
          reboot_target: Atom.to_string(target),
          reboot_boot_id: boot_id,
          draining: true,
          drain_reason: if(draining?, do: box.drain_reason, else: "reboot"),
          previous_os_version:
            if(target == :box and flatcar_update?(box), do: box.os_version, else: nil)
        )
        |> Repo.update!()

      Audit.log(scope, audit_action(target, now?), box, %{
        "boot_id" => boot_id,
        "jobs" => length(VMs.for_box(box.id))
      })

      Activity.record(
        "notice",
        "#{scope.user.login} asked for #{what(box, target)} to reboot",
        box_id: box.id
      )

      if now?, do: reboot_now(box), else: advance(box.id)
      Boxes.broadcast_changed(box.id)
      Crew.Scheduler.poke()
      {:ok, box}
    end
  end

  defp target_boot(%Box{can_restart: true, boot_id: id}, :box) when is_binary(id), do: {:ok, id}
  defp target_boot(%Box{}, :box), do: {:error, :cannot_restart}

  defp target_boot(%Box{type: "mac-vz", cache_vm_reboot: %{"boot_id" => id}}, :cache_vm)
       when is_binary(id),
       do: {:ok, id}

  defp target_boot(%Box{}, :cache_vm), do: {:error, :no_cache_vm}

  defp audit_action(:box, true), do: "box.reboot_now"
  defp audit_action(:box, false), do: "box.reboot"
  defp audit_action(:cache_vm, _), do: "box.cachevm_restart"

  defp what(box, :box), do: box.name
  defp what(box, :cache_vm), do: "#{box.name}'s cache VM"
  defp what(box, "box"), do: what(box, :box)
  defp what(box, "cache_vm"), do: what(box, :cache_vm)

  defp flatcar_update?(%Box{reboot_packages: packages}),
    do: Enum.any?(packages || [], &String.starts_with?(&1, "flatcar-"))

  # Every VM stopped by force, then the reboot, which doesn't wait for them.
  defp reboot_now(box) do
    for vm <- VMs.for_box(box.id) do
      Operations.dispatch(
        box.id,
        "vm.stop",
        %{"vm_id" => vm.id, "reason" => "admin", "force" => true, "grace_s" => 0},
        vm_id: vm.id
      )
    end

    Operations.dispatch(box.id, "box.restart", %{"boot_id" => box.reboot_boot_id, "force" => true})
  end

  @doc "Sends a pending reboot's command once the box has no VM left."
  def advance(box_id) do
    with %Box{reboot_requested_at: %DateTime{}} = box <- Boxes.get(box_id),
         [] <- VMs.for_box(box_id) do
      case box.reboot_target do
        "box" ->
          Operations.dispatch(box.id, "box.restart", %{
            "boot_id" => box.reboot_boot_id,
            "force" => false
          })

        "cache_vm" ->
          Operations.dispatch(box.id, "cachevm.restart", %{"boot_id" => box.reboot_boot_id})

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc "A join (§10.6): a new boot ends the box's reboot; the same boot gets the command again."
  def joined(%Box{reboot_target: "box", reboot_boot_id: was, boot_id: now} = box)
      when is_binary(now) and now != was,
      do: finish(box)

  def joined(%Box{reboot_requested_at: %DateTime{}} = box) do
    advance(box.id)
    box
  end

  def joined(box), do: box

  @doc "A `box.reboot` report: the cache VM on a new boot ends its reboot."
  def reported(%Box{reboot_target: "cache_vm", reboot_boot_id: was} = box, %{
        cache_vm: %{boot_id: now}
      })
      when is_binary(now) and now != was,
      do: finish(box)

  def reported(%Box{reboot_requested_at: nil, previous_os_version: v, os_version: os} = box, _r)
      when is_binary(v) and is_binary(os) and os != v do
    # The update took.
    box |> Ecto.Changeset.change(previous_os_version: nil) |> Repo.update!()
  end

  def reported(box, _r), do: box

  defp finish(box) do
    lift = box.drain_reason == "reboot"
    target = box_target(box)

    {1, [box]} =
      Repo.update_all(
        from(b in Box, where: b.id == ^box.id, select: b),
        set:
          [reboot_requested_at: nil, reboot_target: nil, reboot_boot_id: nil] ++
            if(lift, do: [draining: false, drain_reason: nil], else: [])
      )

    Activity.record("box_rebooted", "#{what(box, target)} came back on a new boot",
      box_id: box.id
    )

    Boxes.broadcast_changed(box.id)
    Crew.Scheduler.poke()
    box
  end

  defp box_target(%Box{reboot_target: t}), do: t || "box"

  @doc "Whether the box came back from a Flatcar update's reboot on the version it had."
  def rolled_back?(%Box{reboot_requested_at: nil, previous_os_version: v, os_version: v})
      when is_binary(v),
      do: true

  def rolled_back?(_box), do: false
end
