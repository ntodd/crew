defmodule Crew.VMs do
  @moduledoc """
  VM rows and their lifecycle (§8.6). Each VM that isn't destroyed has a
  `Crew.VMs.Server`; this module routes what happens to the right one:
  agent events (only for the agent's own box's VMs, §10.4), the join
  inventory (§10.6), the box leaving or being revoked, GitHub naming a
  VM's runner for a job, and the scheduler's placements and reaps.
  """
  import Ecto.Query

  require Logger

  alias Crew.{Images, Operations, Repo}
  alias Crew.VMs.{Server, VM}

  @sup Crew.VMs.Supervisor
  @fork_refused "fork PRs are refused on this repo"
  @live ~w(requested starting booted idle busy finished failed)

  def child_spec(_),
    do: %{
      id: @sup,
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: @sup]]},
      type: :supervisor
    }

  # -- reads ------------------------------------------------------------------------

  def get(id), do: Repo.get(VM, id)
  def get!(id), do: Repo.get!(VM, id)
  def get_by_name(name), do: Repo.get_by(VM, name: name)

  @doc "VMs that aren't destroyed."
  def list_live, do: Repo.all(from v in VM, where: v.state in @live, order_by: v.requested_at)

  def for_box(box_id),
    do:
      Repo.all(
        from v in VM, where: v.box_id == ^box_id and v.state in @live, order_by: v.requested_at
      )

  def subscribe, do: Phoenix.PubSub.subscribe(Crew.PubSub, "vms")

  @doc "A box's VMs with their repos, newest first, for its page."
  def box_vms(box_id) do
    Repo.all(
      from v in VM,
        where: v.box_id == ^box_id and v.state in @live,
        order_by: [desc: v.requested_at],
        preload: :repo
    )
  end

  # -- servers -------------------------------------------------------------------------

  @doc "On control plane boot: a server for every VM that isn't destroyed (§8.6)."
  def boot_servers do
    for vm <- list_live(), do: start_server(:boot, vm.id)
    :ok
  end

  defp start_server(mode, vm_id) do
    case DynamicSupervisor.start_child(@sup, {Server, {mode, vm_id}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> :ignore
      error -> error
    end
  end

  @doc """
  Inserts the scheduler's placements as `requested` VMs in one
  transaction (reserving their allocation), then starts their servers,
  which register the runners and send `vm.start` (§8.3 step 4).
  """
  def create_placements([]), do: []

  def create_placements(placements) do
    deployment = Crew.Settings.ensure_deployment_id()
    now = DateTime.utc_now()
    job_max = Application.get_env(:crew, :job_max_s, 22_500)

    rows =
      for p <- placements do
        id = CrewProtocol.uuid7()
        box = p.box
        {repo_id, key} = p.class

        %{
          id: id,
          box_id: box.id,
          name: CrewProtocol.Names.runner_name(deployment, box.name, id),
          repo_id: repo_id,
          class_key: key,
          class_hash: VM.class_hash(key),
          size_id: p.size.id,
          vcpus: p.size.vcpus,
          memory_mib: p.size.memory_mib,
          disk_gib: p.size.disk_gib,
          # The VMM's, and what the guest kernel keeps (CrewProtocol.GuestMemory).
          vmm_overhead_mib:
            (box.pinned_capabilities["vmm_overhead_mib"] || 0) +
              CrewProtocol.GuestMemory.reserve_mib(p.size.memory_mib),
          image_id: p.image_id,
          state: "requested",
          deadline: DateTime.add(now, job_max, :second),
          requested_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    {:ok, _} = Repo.transact(fn -> {:ok, Repo.insert_all(VM, rows)} end)

    for row <- rows do
      start_server(:new, row.id)
      Phoenix.PubSub.broadcast(Crew.PubSub, "vms", {:vm_changed, row.id})
    end

    rows
  end

  @doc "The scheduler's reap (§8.5)."
  def reap(vm_id, why) do
    Server.event(vm_id, {:reap, Atom.to_string(why)})
    :ok
  end

  # -- agent events (§10.4) -------------------------------------------------------------

  @doc "An event from a box's agent about its VMs, images or cache."
  def handle_agent_event(box_id, %CrewProtocol.Event{type: "box.inventory", payload: inventory}) do
    :persistent_term.put({__MODULE__, :inventory, box_id}, inventory)
    apply_inventory(box_id, inventory)
    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{box_id}", {:box_changed, box_id})
    :ok
  end

  # Progress comes every few seconds while a box prepares an image; only
  # an end (ready or failed) can change a pass. An image the control
  # plane no longer has is ignored.
  def handle_agent_event(box_id, %CrewProtocol.Event{type: "image.state", payload: p}) do
    if Images.get(p.image_id) do
      Images.put_box_state(box_id, p.image_id, p.state, progress: p.progress, error: p[:error])
      if p.state in ["ready", "failed"], do: Crew.Scheduler.poke()
    end

    :ok
  end

  def handle_agent_event(box_id, %CrewProtocol.Event{type: "cache.stats", payload: p}),
    do: Crew.Caches.record_stats(box_id, p)

  def handle_agent_event(box_id, %CrewProtocol.Event{
        type: "vm." <> _ = type,
        payload: %{vm_id: vm_id} = p
      }) do
    case get(vm_id) do
      %VM{box_id: ^box_id} = vm ->
        vm_event(vm, type, p)

      %VM{} ->
        Logger.warning("box #{box_id} reported on VM #{vm_id}, which isn't its own")
        {:error, "not this box's VM"}

      nil ->
        # A VM this control plane doesn't know (§10.6): stop it if it's alive.
        if type == "vm.state", do: stop_unknown(box_id, vm_id)
        :ok
    end
  end

  defp vm_event(vm, "vm.state", %{state: state} = p) do
    case state do
      "booted" -> Server.event(vm.id, :booted)
      "runner_listening" -> Server.event(vm.id, :runner_listening)
      "job_started" -> Server.event(vm.id, :guest_job_started)
      "job_refused" -> refused(vm, p[:detail])
      _ -> :ok
    end

    :ok
  end

  defp vm_event(vm, "vm.exited", p) do
    Server.event(vm.id, {:exited, p.reason, if(p.cleanup == "ok", do: :ok, else: :error)})
    :ok
  end

  # Logs, steps and metrics (§16).
  defp vm_event(vm, type, payload), do: Crew.Logs.handle_agent_event(vm, type, payload)

  # The guest's job-started hook refused a fork PR (§19.5).
  defp refused(vm, _detail) do
    Crew.Activity.record("fork_refused", "A Crew runner refused a fork PR's job (VM #{vm.name})",
      repo_id: vm.repo_id,
      masked: "A Crew runner refused a fork PR's job in another repo"
    )
  end

  defp stop_unknown(box_id, vm_id) do
    Operations.dispatch(box_id, "vm.stop", %{
      "vm_id" => vm_id,
      "reason" => "lost",
      "force" => true,
      "grace_s" => 0
    })
  end

  @doc "The join inventory (§10.6): adopt, stop or lose each VM."
  def apply_inventory(box_id, %{vms: listed, images: images}) do
    listed_by_id = Map.new(listed, &{&1.vm_id, &1})

    vms = for_box(box_id)

    # A requested VM's vm.start may still be on its way, so its absence
    # means nothing yet: the ack timeout covers a lost one. A listed VM
    # that has exited gets its vm.exited from the agent's outbox.
    for vm <- vms, vm.state != "requested" do
      case Map.get(listed_by_id, vm.id) do
        nil -> Server.event(vm.id, :inventory_missing)
        %{alive: true} -> Server.event(vm.id, :inventory_alive)
        %{alive: false} -> :ok
      end
    end

    known = MapSet.new(vms, & &1.id)

    for %{alive: true, vm_id: id} <- listed,
        not MapSet.member?(known, id),
        do: stop_unknown(box_id, id)

    for %{id: id, state: state} <- images,
        Images.get(id),
        do: Images.put_box_state(box_id, id, state)

    Images.forget_unlisted(box_id, Enum.map(images, & &1.id))

    :ok
  end

  @doc "A box's agent joined: its inventory follows (§10.6)."
  def agent_joined(_box, _join), do: :ok

  @doc "A box's agent left (§8.6 \"box disconnects\")."
  def agent_left(box_id) do
    for vm <- for_box(box_id), do: Server.event(vm.id, :box_disconnected)
    Crew.Scheduler.poke()
    :ok
  end

  @doc "A box was revoked: all its VMs are destroyed."
  def box_revoked(box_id) do
    for vm <- for_box(box_id), do: Server.event(vm.id, :box_revoked)
    :ok
  end

  @doc "The last inventory a box's agent sent, if any."
  def inventory(box_id), do: :persistent_term.get({__MODULE__, :inventory, box_id}, nil)

  # -- jobs ---------------------------------------------------------------------------------

  @doc """
  GitHub named one of this deployment's runners for a job (§8.2): link
  the VM, whatever the job's classification. A refused fork job on a
  Crew VM is stopped at once (§19.5).
  """
  def job_event(job, state) do
    with name when is_binary(name) <- job.runner_name,
         %VM{} = vm <- get_by_name(name) do
      event =
        case state do
          "in_progress" -> {:job_started, job.id}
          "completed" -> {:job_completed, job.id}
          _ -> nil
        end

      if event && Server.event(vm.id, event) == {:error, :no_server}, do: late_link(vm, job)

      if state == "in_progress" and job.unsatisfiable_reason == @fork_refused,
        do: stop_refused(vm)
    end

    :ok
  end

  # GitHub's webhooks can come after the VM is gone (a short job's guest
  # powers off first): the job and the VM still get linked, and nothing
  # else about the VM changes.
  defp late_link(vm, job) do
    Repo.update_all(from(v in VM, where: v.id == ^vm.id and is_nil(v.job_id)),
      set: [job_id: job.id]
    )

    if is_nil(job.vm_id), do: Crew.Jobs.link_vm(job.id, vm)
    Phoenix.PubSub.broadcast(Crew.PubSub, "vm:#{vm.id}", {:vm_changed, vm.id})
  end

  defp stop_refused(vm) do
    Operations.dispatch(vm.box_id, "vm.stop", %{
      "vm_id" => vm.id,
      "reason" => "refused",
      "force" => true,
      "grace_s" => 0
    })

    if vm.runner_id,
      do:
        %{repo_id: vm.repo_id, runner_id: vm.runner_id}
        |> Crew.VMs.DeleteRunner.new()
        |> Oban.insert()

    Crew.Activity.record("fork_refused", "Stopped a Crew VM that took a refused fork PR's job",
      repo_id: vm.repo_id,
      masked: "Stopped a Crew VM that took a refused fork PR's job in another repo"
    )
  end

  @doc """
  An admin kills a VM (§17.3): a forced stop, recorded in the activity
  feed and the audit log. Its server takes it from there when it exits.
  """
  def kill(%Crew.Scope{} = scope, %VM{} = vm) do
    if Crew.Scope.admin?(scope) do
      result =
        Operations.dispatch(
          vm.box_id,
          "vm.stop",
          %{"vm_id" => vm.id, "reason" => "admin", "force" => true, "grace_s" => 0},
          vm_id: vm.id,
          user_id: scope.user.id
        )

      Crew.Audit.log(scope, "vm.kill", vm, %{"name" => vm.name})

      Crew.Activity.record("vm_killed", "#{scope.user.login} killed VM #{vm.name}",
        box_id: vm.box_id,
        repo_id: vm.repo_id,
        masked: "An admin killed a VM of another repo"
      )

      case result do
        {:ok, _} -> :ok
        {:error, :offline} -> {:error, :offline}
        other -> other
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc "What a box's VMs hold of it: every VM that isn't destroyed counts (§8.6)."
  def allocation(box_id) do
    vms = for_box(box_id)

    %{
      vcpus: Enum.sum_by(vms, & &1.vcpus),
      memory_mib: Enum.sum_by(vms, &(&1.memory_mib + &1.vmm_overhead_mib)),
      count: length(vms)
    }
  end
end
