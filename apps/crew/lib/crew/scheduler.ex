defmodule Crew.Scheduler do
  @moduledoc """
  The scheduling loop (§8.3, §9.3). Each pass builds a snapshot from the
  database, runs `Crew.Scheduler.Plan.plan/1` on it and applies the
  actions: placements become `requested` VMs (and their servers), jobs
  get their blocked and wait reasons, idle VMs are reaped and boxes are
  sent `image.prepare`.

  A pass runs at least once a second, and after `poke/0` (a job queued,
  a VM changed state, a box came or went), no more often than every
  200 ms. Passes never overlap: they run in this process.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias Crew.{Agents, Boxes, Images, Jobs, Metrics, Operations, Repo, Repos, Sizes, VMs}
  alias Crew.Jobs.Job
  alias Crew.Scheduler.{ClassState, Plan}

  @min_gap_ms 200
  @booting "booting a runner on "
  @tick_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for a pass soon. A no-op when the scheduler isn't running (tests run passes directly)."
  def poke do
    if pid = Process.whereis(__MODULE__), do: send(pid, :poke)
    :ok
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{last: nil, timer: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, run(state)}
  end

  def handle_info(:poke, %{timer: nil} = state) do
    now = System.monotonic_time(:millisecond)
    wait = if state.last, do: max(0, @min_gap_ms - (now - state.last)), else: 0
    {:noreply, %{state | timer: Process.send_after(self(), :run, wait)}}
  end

  def handle_info(:poke, state), do: {:noreply, state}
  def handle_info(:run, state), do: {:noreply, run(%{state | timer: nil})}
  def handle_info(_msg, state), do: {:noreply, state}

  defp run(state) do
    try do
      pass()
    rescue
      e -> Logger.error("scheduler pass failed: " <> Exception.format(:error, e, __STACKTRACE__))
    end

    %{state | last: System.monotonic_time(:millisecond)}
  end

  # -- one pass ----------------------------------------------------------------------

  @doc "Runs one pass: snapshot, plan, apply. Returns the actions."
  def pass do
    snap = snapshot()
    actions = Plan.plan(snap)
    apply_actions(snap, actions)
    actions
  end

  @doc "The database as the plan sees it (§8.3)."
  def snapshot(now \\ DateTime.utc_now()) do
    sizes = Sizes.list()
    boxes = Enum.flat_map(Boxes.list(), &snapshot_box/1)

    %{
      now: ms(now),
      settings: %{
        idle_grace_s: Application.get_env(:crew, :idle_grace_s, 30),
        idle_max_s: Application.get_env(:crew, :idle_max_s, 600)
      },
      sizes: Map.new(sizes, &{&1.id, Map.take(&1, [:id, :name, :vcpus, :memory_mib, :disk_gib])}),
      repos:
        Map.new(
          Repos.list(),
          &{&1.id, Map.take(&1, [:id, :priority, :max_concurrent, :allowed_boxes])}
        ),
      boxes: boxes,
      images: Images.defaults(),
      box_images: Images.box_states(now),
      jobs: queued_jobs(),
      vms: Enum.map(VMs.list_live(), &snapshot_vm/1),
      class_state: class_state()
    }
  end

  @doc """
  The Queue page (§17.3): a pass's units in placement order, the blocked
  jobs, and each class, with the jobs and repos they're about. Jobs in
  repos the scope can't read are masked by the page.
  """
  def queue_view do
    snap = snapshot()
    queue = Plan.queue(snap)

    ids =
      Enum.map(queue.units, & &1.job_id) ++ Enum.map(queue.blocked, &elem(&1, 0)) ++ queue.covered

    jobs = Repo.all(from j in Job, where: j.id in ^ids, preload: [:size]) |> Map.new(&{&1.id, &1})
    %{queue: queue, jobs: jobs, repos: Map.new(Repos.list(), &{&1.id, &1})}
  end

  @doc """
  The label tester (§17.3): how a `runs-on` value parses (`crew-m`,
  `[self-hosted, crew-m]` or a YAML list), and which boxes could hold it.
  """
  def label_test(text) do
    labels = CrewProtocol.Labels.parse_runs_on(text)
    sizes = Sizes.list()

    result =
      case labels do
        [] -> :empty
        _ -> CrewProtocol.Labels.parse(labels, Sizes.for_parse(), Sizes.aliases_for_parse())
      end

    boxes =
      case result do
        {:ours, %{size_id: size_id, arch: arch}} ->
          size = Enum.find(sizes, &(&1.id == size_id))

          for b <- snapshot().boxes, Plan.arch_ok?(b, arch), Plan.could_hold?(b, size), do: b.name

        _ ->
          []
      end

    %{
      labels: labels,
      key: CrewProtocol.Labels.key(labels),
      result: result,
      boxes: boxes,
      sizes: Map.new(sizes, &{&1.id, &1})
    }
  end

  @doc "What a box offers job VMs (overcommit included), or nil before it reports."
  def capacity(box) do
    case snapshot_box(box) do
      [b] -> %{vcpus: Plan.allocatable_vcpus(b), memory_mib: Plan.allocatable_memory_mib(b)}
      [] -> nil
    end
  end

  # A box that hasn't reported capabilities can't be placed on yet.
  defp snapshot_box(%{pinned_capabilities: nil}), do: []

  defp snapshot_box(box) do
    caps = caps(box.pinned_capabilities, box.capabilities || box.pinned_capabilities)
    free = with %{vm_area_free_mib: free} <- Metrics.latest_box(box.id), do: free

    [
      %{
        id: box.id,
        name: box.name,
        online: Agents.online?(box.id),
        draining: box.draining,
        quarantined_until: box.quarantined_until && ms(box.quarantined_until),
        needs_approval: box.needs_approval,
        firewall_ok: box.firewall_ok,
        guest_arch: box.guest_arch,
        caps: caps,
        allocatable_vcpus_override: box.allocatable_vcpus_override,
        allocatable_memory_mib_override: box.allocatable_memory_mib_override,
        reserve_vcpus: box.reserve_vcpus,
        reserve_memory_mib: box.reserve_memory_mib,
        cpu_overcommit: box.cpu_overcommit,
        max_vms: box.max_vms,
        vm_area_free_mib: free || caps.vm_area_mib,
        last_repo_ran_at: box.last_repo_ran_at || %{},
        record: box
      }
    ]
  end

  # Placement uses the smaller of the pinned and the reported capabilities
  # (§8.3), and the larger VMM overhead.
  defp caps(pinned, reported) do
    min = fn key -> min(num(pinned[key]), num(reported[key])) end

    %{
      vcpus: min.("vcpus"),
      memory_mib: min.("memory_mib"),
      vm_area_mib: min.("vm_area_mib"),
      max_vcpus_per_vm: min.("max_vcpus_per_vm"),
      max_memory_mib_per_vm: min.("max_memory_mib_per_vm"),
      vmm_overhead_mib: max(num(pinned["vmm_overhead_mib"]), num(reported["vmm_overhead_mib"]))
    }
  end

  defp num(n) when is_integer(n), do: n
  defp num(_), do: 0

  defp queued_jobs do
    Repo.all(
      from j in Job,
        where: j.classification == "ours" and j.gh_state == "queued" and is_nil(j.vm_id),
        select:
          map(j, [
            :id,
            :github_id,
            :repo_id,
            :label_key,
            :size_id,
            :arch,
            :queued_at,
            :inserted_at,
            :blocked_reason,
            :wait_reason
          ])
    )
    |> Enum.map(fn j ->
      %{
        id: j.id,
        github_id: j.github_id,
        repo_id: j.repo_id,
        class: {j.repo_id, j.label_key},
        label_key: j.label_key,
        size_id: j.size_id,
        arch: arch(j.arch),
        queued_at: ms(j.queued_at || j.inserted_at),
        blocked_reason: j.blocked_reason,
        wait_reason: j.wait_reason
      }
    end)
  end

  defp arch("x64"), do: :x64
  defp arch("arm64"), do: :arm64
  defp arch(_), do: :any

  defp snapshot_vm(vm) do
    %{
      id: vm.id,
      box_id: vm.box_id,
      repo_id: vm.repo_id,
      class: {vm.repo_id, vm.class_key},
      vcpus: vm.vcpus,
      memory_mib: vm.memory_mib,
      disk_gib: vm.disk_gib,
      vmm_overhead_mib: vm.vmm_overhead_mib,
      state: vm.state,
      job_id: vm.job_id,
      requested_at: ms(vm.requested_at),
      idle_at: vm.idle_at && ms(vm.idle_at),
      image_id: vm.image_id
    }
  end

  defp class_state do
    for cs <- Repo.all(ClassState), into: %{} do
      {{cs.repo_id, cs.class_key},
       %{
         consecutive_failures: cs.consecutive_failures,
         last_error: cs.last_error,
         backoff_until: cs.backoff_until && ms(cs.backoff_until),
         stalled_until: cs.stalled_until && ms(cs.stalled_until),
         excess_since: cs.excess_since && ms(cs.excess_since)
       }}
    end
  end

  # -- applying the plan ---------------------------------------------------------------

  defp apply_actions(snap, actions) do
    boxes = Map.new(snap.boxes, &{&1.id, &1.record})
    sizes = Map.new(Sizes.list(), &{&1.id, &1})

    placements =
      for {:place, p} <- actions do
        %{
          job_id: p.job_id,
          class: p.class,
          box: Map.fetch!(boxes, p.box_id),
          size: Map.fetch!(sizes, p.size_id),
          image_id: p.image_id
        }
      end

    VMs.create_placements(placements)

    booting = Map.new(placements, &{&1.job_id, @booting <> &1.box.name})

    reasons =
      for {:reasons, id, blocked, wait} <- actions,
          into: %{},
          do: {id, {blocked, Map.get(booting, id, wait)}}

    update_reasons(snap.jobs, reasons)

    for {:reap, vm_id, why} <- actions, do: VMs.reap(vm_id, why)
    for {:excess_since, class, at} <- actions, do: put_excess_since(class, at)
    for {:prepare_image, box_id, image_id} <- actions, do: prepare_image(box_id, image_id)
    for {:remove_image, box_id, image_id} <- actions, do: remove_image(box_id, image_id)
    :ok
  end

  # Only the jobs whose reasons changed are written. A job a runner was
  # booted for keeps saying so while that supply covers it.
  defp update_reasons(jobs, reasons) do
    for job <- jobs do
      current = {job.blocked_reason, job.wait_reason}

      next =
        case Map.get(reasons, job.id, current) do
          {nil, nil} -> if booting?(job.wait_reason), do: current, else: {nil, nil}
          other -> other
        end

      if next != current do
        {blocked, wait} = next

        Repo.update_all(from(j in Job, where: j.id == ^job.id),
          set: [blocked_reason: blocked, wait_reason: wait, updated_at: DateTime.utc_now()]
        )

        Jobs.changed(job.id)
      end
    end
  end

  defp booting?(reason), do: is_binary(reason) and String.starts_with?(reason, @booting)

  defp put_excess_since({repo_id, key}, at) do
    now = DateTime.utc_now()
    hash = Crew.VMs.VM.class_hash(key)
    value = at && DateTime.from_unix!(at * 1000, :microsecond)

    Repo.insert_all(
      ClassState,
      [
        %{
          repo_id: repo_id,
          class_hash: hash,
          class_key: key,
          excess_since: value,
          updated_at: now
        }
      ],
      on_conflict: [set: [excess_since: value, updated_at: now]],
      conflict_target: [:repo_id, :class_hash]
    )
  end

  defp prepare_image(box_id, image_id) do
    with %{} = image <- Images.get(image_id),
         {:ok, %{status: "dispatched"}} <-
           Operations.dispatch(box_id, "image.prepare", Images.prepare_payload(image)) do
      Images.put_box_state(box_id, image_id, "downloading")
    end
  end

  # Marked removing so it isn't sent again each pass; the agent's next
  # inventory drops the row once the image is gone (or puts it back).
  defp remove_image(box_id, image_id) do
    with {:ok, %{status: "dispatched"}} <-
           Operations.dispatch(box_id, "image.remove", %{image_id: image_id}) do
      Images.put_box_state(box_id, image_id, "removing")
    end
  end

  defp ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
end
