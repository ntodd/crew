defmodule Crew.Scheduler.Plan do
  @moduledoc """
  One scheduling pass, as a pure function (§8.3):
  `plan(snapshot) -> [action]`. `Crew.Scheduler` builds the snapshot
  from the database and applies the actions.

  1. **Blocked reasons** (§8.2): a job that can't be placed for a reason
     static to this pass (no boxes, no box of its arch, no box that could
     ever hold its size, only ineligible boxes, a stalled class, its repo
     at `max_concurrent`) is blocked, and isn't demand.
  2. **Demand and supply per class** (§8.1). The first `supply(class)`
     jobs of a class, in order, are covered; each other one is a unit.
  3. **Units in order** (§8.4): priority, the repo's active VMs
     (recomputed after each placement, so repos alternate), `queued_at`,
     GitHub id. Each is placed on the best eligible box, and the
     placement is added to the snapshot before the next.
  4. **Reaping** (§8.5): excess idle VMs once the excess has lasted
     `idle_grace`, newest first; any VM idle for `idle_max`; draining
     boxes' idle VMs.
  5. **Images**: a box missing its arch's default image is sent
     `image.prepare`.

  Actions:
  - `{:place, %{job_id, class, repo_id, box_id, size_id, image_id}}`
  - `{:reasons, job_id, blocked_reason | nil, wait_reason | nil}`
  - `{:reap, vm_id, :excess | :idle_max | :draining}`
  - `{:excess_since, class, ms | nil}`
  - `{:prepare_image, box_id, image_id}`
  """

  @active ~w(requested starting booted idle busy)
  @supply ~w(requested starting booted idle)
  @projected ~w(requested starting booted)
  @checking_fork "checking fork status"

  @type snapshot :: map()
  @type action :: tuple()

  @spec plan(snapshot()) :: [action()]
  def plan(snap) do
    snap = Map.put(snap, :placements, [])
    jobs = Enum.sort_by(snap.jobs, &{&1.queued_at, &1.github_id})

    # Jobs the fork check holds are the jobs context's; they're left alone.
    {held, jobs} = Enum.split_with(jobs, &(&1.blocked_reason == @checking_fork))
    _ = held

    {blocked, open} =
      Enum.split_with(Enum.map(jobs, &{&1, static_reason(snap, &1)}), fn {_, r} -> r end)

    blocked_actions = for {job, reason} <- blocked, do: {:reasons, job.id, reason, nil}
    open = Enum.map(open, &elem(&1, 0))

    {covered, units} = units(snap, open)
    covered_actions = for job <- covered, do: {:reasons, job.id, nil, nil}

    {snap, placement_actions} = place_all(snap, units)

    blocked_actions ++
      covered_actions ++
      placement_actions ++ reap(snap, open) ++ prepare_images(snap)
  end

  @doc """
  The Queue page's view of a pass (§17.3): the units in the order they'd
  be placed, each placed or with its wait reason; the covered jobs; the
  blocked ones with their reasons; and per class its demand, supply,
  deficit, and whether it's stalled or backing off.
  """
  def queue(snap) do
    snap = Map.put(snap, :placements, [])

    jobs =
      snap.jobs
      |> Enum.sort_by(&{&1.queued_at, &1.github_id})
      |> Enum.reject(&(&1.blocked_reason == @checking_fork))

    {blocked, open} =
      Enum.split_with(Enum.map(jobs, &{&1, static_reason(snap, &1)}), fn {_, r} -> r end)

    open = Enum.map(open, &elem(&1, 0))
    {covered, units} = units(snap, open)
    {_snap, actions} = place_all(snap, units)

    by_id = Map.new(units, &{&1.id, &1})
    placed = MapSet.new(for {:place, p} <- actions, do: p.job_id)

    ordered =
      for {:reasons, id, blocked_reason, wait} <- actions, unit = by_id[id] do
        %{
          job_id: id,
          class: unit.class,
          placed: MapSet.member?(placed, id),
          wait_reason: wait,
          blocked_reason: blocked_reason
        }
      end

    demand = Enum.frequencies_by(open, & &1.class)
    blocked_by_class = Enum.frequencies_by(blocked, fn {job, _} -> job.class end)

    classes =
      for class <- Enum.uniq(Map.keys(demand) ++ Map.keys(blocked_by_class)), into: %{} do
        cs = snap.class_state[class] || %{}
        sup = supply(snap, class)
        n = Map.get(demand, class, 0)

        {class,
         %{
           demand: n,
           blocked: Map.get(blocked_by_class, class, 0),
           supply: sup,
           deficit: max(n - sup, 0),
           stalled: is_integer(cs[:stalled_until]) and cs[:stalled_until] > snap.now,
           backoff: is_integer(cs[:backoff_until]) and cs[:backoff_until] > snap.now,
           last_error: cs[:last_error]
         }}
      end

    %{
      units: ordered,
      covered: Enum.map(covered, & &1.id),
      blocked: for({job, reason} <- blocked, do: {job.id, reason}),
      classes: classes
    }
  end

  # -- capacity (§8.3) -------------------------------------------------------------

  @doc "vCPUs the box offers job VMs, overcommit included."
  def allocatable_vcpus(box) do
    base = box.allocatable_vcpus_override || box.caps.vcpus - (box.reserve_vcpus || 1)
    base * (box.cpu_overcommit || 1.5)
  end

  @doc "Memory the box offers job VMs (never overcommitted)."
  def allocatable_memory_mib(box) do
    box.allocatable_memory_mib_override ||
      box.caps.memory_mib - (box.reserve_memory_mib || 2048 + floor(0.05 * box.caps.memory_mib))
  end

  defp size(snap, job), do: Map.fetch!(snap.sizes, job.size_id)

  defp vms_on(snap, box_id), do: Enum.filter(all_vms(snap), &(&1.box_id == box_id))

  # Existing VMs and this pass's placements, as allocations.
  defp all_vms(snap), do: snap.vms ++ snap.placements

  defp fit(snap, box, size) do
    vms = vms_on(snap, box.id)
    overhead = box.caps.vmm_overhead_mib
    mem_used = Enum.reduce(vms, 0, &(&1.memory_mib + (&1.vmm_overhead_mib || overhead) + &2))
    vcpus_used = Enum.reduce(vms, 0, &(&1.vcpus + &2))

    projected =
      box.vm_area_free_mib -
        Enum.reduce(vms, 0, fn vm, acc ->
          if vm.state in @projected, do: acc + 0.5 * vm.disk_gib * 1024, else: acc
        end)

    cond do
      size.vcpus > box.caps.max_vcpus_per_vm or size.memory_mib > box.caps.max_memory_mib_per_vm ->
        {:no, :per_vm}

      mem_used + size.memory_mib + overhead > allocatable_memory_mib(box) ->
        {:no, {:memory, allocatable_memory_mib(box) - mem_used}}

      vcpus_used + size.vcpus > allocatable_vcpus(box) ->
        {:no, {:vcpus, allocatable_vcpus(box) - vcpus_used}}

      projected - 0.5 * size.disk_gib * 1024 < 0.15 * box.caps.vm_area_mib ->
        {:no, :disk}

      box.max_vms != nil and length(vms) >= box.max_vms ->
        {:no, :max_vms}

      true ->
        {:ok, (mem_used + size.memory_mib + overhead) / max(allocatable_memory_mib(box), 1)}
    end
  end

  # Whether the box could hold the size at all, empty.
  @doc "Whether a box could ever hold a VM of `size` (its limits and what it offers)."
  def could_hold?(box, size) do
    size.vcpus <= box.caps.max_vcpus_per_vm and size.memory_mib <= box.caps.max_memory_mib_per_vm and
      size.memory_mib + box.caps.vmm_overhead_mib <= allocatable_memory_mib(box) and
      size.vcpus <= allocatable_vcpus(box)
  end

  @doc false
  def arch_ok?(_box, :any), do: true
  def arch_ok?(box, arch), do: box.guest_arch == Atom.to_string(arch)

  defp state_ok?(box, now) do
    box.online and not box.draining and not box.needs_approval and box.firewall_ok and
      (is_nil(box.quarantined_until) or box.quarantined_until <= now)
  end

  defp state_label(box, now) do
    cond do
      not box.online -> "offline"
      box.draining -> "draining"
      box.needs_approval -> "awaiting approval"
      not box.firewall_ok -> "without a verified firewall"
      box.quarantined_until && box.quarantined_until > now -> "quarantined"
      true -> nil
    end
  end

  defp allowed?(snap, job, box) do
    case snap.repos[job.repo_id] do
      %{allowed_boxes: list} when is_list(list) -> box.id in list
      _ -> true
    end
  end

  # -- blocked reasons (§8.2) -------------------------------------------------------

  defp static_reason(snap, job) do
    size = size(snap, job)
    class = job.class
    cs = snap.class_state[class] || %{}
    boxes = Enum.filter(snap.boxes, &allowed?(snap, job, &1))
    arch_boxes = Enum.filter(boxes, &arch_ok?(&1, job.arch))
    holding = Enum.filter(arch_boxes, &could_hold?(&1, size))

    cond do
      cs[:stalled_until] && cs[:stalled_until] > snap.now ->
        {_repo, key} = class

        "GitHub isn't assigning jobs to runners labelled [#{Enum.join(key, ", ")}]: " <>
          "check labels and the runner version"

      snap.boxes == [] ->
        "no boxes enrolled"

      boxes == [] ->
        "none of the repo's allowed boxes are enrolled"

      arch_boxes == [] ->
        "no #{job.arch} box"

      holding == [] ->
        "no box could ever hold this size"

      not Enum.any?(holding, &state_ok?(&1, snap.now)) ->
        labels =
          holding |> Enum.map(&state_label(&1, snap.now)) |> Enum.uniq() |> Enum.join(" / ")

        "the only boxes that fit are #{labels}"

      true ->
        nil
    end
  end

  # -- demand, supply and units (§8.1) ----------------------------------------------

  defp supply_vm?(snap, vm) do
    box = Enum.find(snap.boxes, &(&1.id == vm.box_id))
    vm.state in @supply and is_nil(vm.job_id) and box != nil and box.online and not box.draining
  end

  defp supply(snap, class),
    do: Enum.count(snap.vms, &(&1.class == class and supply_vm?(snap, &1)))

  defp units(snap, open) do
    open
    |> Enum.group_by(& &1.class)
    |> Enum.reduce({[], []}, fn {class, jobs}, {covered, units} ->
      {c, u} = Enum.split(jobs, supply(snap, class))
      {covered ++ c, units ++ u}
    end)
  end

  # -- placement (§8.3, §8.4) ---------------------------------------------------------

  defp place_all(snap, units) do
    active =
      Enum.reduce(snap.vms, %{}, fn vm, acc ->
        if vm.state in @active, do: Map.update(acc, vm.repo_id, 1, &(&1 + 1)), else: acc
      end)

    do_place(snap, units, active, [])
  end

  defp do_place(snap, [], _active, acc), do: {snap, Enum.reverse(acc)}

  defp do_place(snap, units, active, acc) do
    unit = Enum.min_by(units, &order_key(snap, &1, active))
    rest = List.delete(units, unit)
    repo = snap.repos[unit.repo_id] || %{}

    cond do
      repo[:max_concurrent] && Map.get(active, unit.repo_id, 0) >= repo[:max_concurrent] ->
        do_place(snap, rest, active, [{:reasons, unit.id, "repo at max_concurrent", nil} | acc])

      backoff = in_backoff(snap, unit.class) ->
        msg =
          "Crew can't start runners for this class: #{backoff[:last_error] || "repeated failures"}"

        do_place(snap, rest, active, [{:reasons, unit.id, nil, msg} | acc])

      true ->
        case best_box(snap, unit) do
          {:ok, box, image_id} ->
            size = size(snap, unit)

            placed = %{
              job_id: unit.id,
              class: unit.class,
              repo_id: unit.repo_id,
              box_id: box.id,
              size_id: unit.size_id,
              image_id: image_id
            }

            vm = %{
              id: {:placement, length(snap.placements)},
              box_id: box.id,
              repo_id: unit.repo_id,
              class: unit.class,
              vcpus: size.vcpus,
              memory_mib: size.memory_mib,
              disk_gib: size.disk_gib,
              vmm_overhead_mib: box.caps.vmm_overhead_mib,
              state: "requested",
              job_id: nil
            }

            snap = %{snap | placements: snap.placements ++ [vm]}
            active = Map.update(active, unit.repo_id, 1, &(&1 + 1))
            do_place(snap, rest, active, [{:reasons, unit.id, nil, nil}, {:place, placed} | acc])

          {:no, reason} ->
            do_place(snap, rest, active, [{:reasons, unit.id, nil, reason} | acc])
        end
    end
  end

  defp order_key(snap, job, active) do
    priority = (snap.repos[job.repo_id] || %{})[:priority] || 0
    {-priority, Map.get(active, job.repo_id, 0), job.queued_at, job.github_id}
  end

  defp in_backoff(snap, class) do
    case snap.class_state[class] do
      %{backoff_until: until} = cs when is_integer(until) -> if until > snap.now, do: cs
      _ -> nil
    end
  end

  defp best_box(snap, unit) do
    size = size(snap, unit)

    candidates =
      for box <- snap.boxes,
          allowed?(snap, unit, box),
          arch_ok?(box, unit.arch),
          state_ok?(box, snap.now),
          do: {box, usable_image(snap, box)}

    fits =
      for {box, {image_id, default?}} <- candidates,
          image_id != nil,
          {:ok, fraction} <- [fit(snap, box, size)],
          do: {box, image_id, default?, fraction}

    case Enum.sort_by(fits, &rank_key(&1, unit)) do
      [{box, image_id, _, _} | _] -> {:ok, box, image_id}
      [] -> {:no, why_not(snap, candidates, size)}
    end
  end

  defp rank_key({box, _image, default?, fraction}, unit) do
    last = Map.get(box.last_repo_ran_at || %{}, unit.repo_id, 0)
    {if(default?, do: 0, else: 1), fraction, -last, box.name}
  end

  # The wait reason for a unit nothing could take right now.
  defp why_not(_snap, [], _size), do: "no eligible box is online"

  defp why_not(snap, candidates, size) do
    with_image = for {box, {id, _}} <- candidates, id != nil, do: box

    if with_image == [] do
      "no box has the image ready yet"
    else
      results = Enum.map(with_image, &{&1, fit(snap, &1, size)})

      case Enum.filter(results, &match?({_, {:no, {:memory, _}}}, &1)) do
        [_ | _] = mem ->
          {box, {:no, {:memory, free}}} = Enum.max_by(mem, fn {_, {:no, {:memory, f}}} -> f end)

          "no box with #{gib(size.memory_mib)} GiB free (largest free: #{gib(max(free, 0))} GiB on #{box.name})"

        [] ->
          results |> Enum.map(fn {_, {:no, r}} -> r end) |> no_room(size)
      end
    end
  end

  defp no_room([{:vcpus, _} | _], size), do: "no box with #{size.vcpus} vCPUs free"
  defp no_room([:disk | _], _size), do: "no box with room on its clone area"
  defp no_room([:max_vms | _], _size), do: "every box that could take it is at its VM limit"
  defp no_room(_, _size), do: "no box has room"

  defp gib(mib),
    do:
      mib
      |> Kernel./(1024)
      |> Float.round(1)
      |> then(&if(&1 == trunc(&1), do: trunc(&1), else: &1))

  # -- images (§8.3) ---------------------------------------------------------------

  @doc """
  The image a box would boot for its arch, and whether it's the default:
  the default if it's ready here, else the newest ready one that was the
  default within the last two registered releases, else none.
  """
  def usable_image(snap, box) do
    case snap.images[box.guest_arch] do
      nil ->
        {nil, false}

      %{default: default, recent_defaults: recent} ->
        cond do
          snap.box_images[{box.id, default}] == "ready" -> {default, true}
          id = Enum.find(recent, &(snap.box_images[{box.id, &1}] == "ready")) -> {id, false}
          true -> {nil, false}
        end
    end
  end

  defp prepare_images(snap) do
    for box <- snap.boxes,
        box.online,
        %{default: default} <- [snap.images[box.guest_arch]],
        default != nil,
        snap.box_images[{box.id, default}] in [nil, "retry"],
        do: {:prepare_image, box.id, default}
  end

  # -- reaping (§8.5) ---------------------------------------------------------------

  # A class's excess: noted when it starts, reaped once it has lasted
  # idle_grace (newest idle first), cleared when it's gone.
  defp class_excess(snap, class, excess) do
    since = (snap.class_state[class] || %{})[:excess_since]

    cond do
      excess > 0 and is_nil(since) ->
        {[{:excess_since, class, snap.now}], []}

      excess > 0 and snap.now - since >= snap.settings.idle_grace_s * 1000 ->
        {[], excess_reaps(snap, class, excess)}

      excess <= 0 and since != nil ->
        {[{:excess_since, class, nil}], []}

      true ->
        {[], []}
    end
  end

  defp excess_reaps(snap, class, excess) do
    snap.vms
    |> Enum.filter(
      &(&1.class == class and &1.state == "idle" and is_nil(&1.job_id) and supply_vm?(snap, &1))
    )
    |> Enum.sort_by(&(&1.idle_at || 0), :desc)
    |> Enum.take(excess)
    |> Enum.map(&{:reap, &1.id, :excess})
  end

  defp reap(snap, open) do
    demand = Enum.frequencies_by(open, & &1.class)
    classes = snap.vms |> Enum.map(& &1.class) |> Enum.uniq()

    {excess_actions, excess_reaps} =
      Enum.reduce(classes, {[], []}, fn class, {actions, reaps} ->
        {a, r} = class_excess(snap, class, supply(snap, class) - Map.get(demand, class, 0))
        {a ++ actions, reaps ++ r}
      end)

    idle_max_ms = snap.settings.idle_max_s * 1000

    others =
      for vm <- snap.vms,
          vm.state == "idle",
          is_nil(vm.job_id),
          reason = other_reap(snap, vm, idle_max_ms),
          do: {:reap, vm.id, reason}

    taken = MapSet.new(others, &elem(&1, 1))

    Enum.reverse(excess_actions) ++
      others ++ Enum.reject(excess_reaps, &MapSet.member?(taken, elem(&1, 1)))
  end

  defp other_reap(snap, vm, idle_max_ms) do
    box = Enum.find(snap.boxes, &(&1.id == vm.box_id))

    cond do
      vm.idle_at && snap.now - vm.idle_at >= idle_max_ms -> :idle_max
      box && box.draining -> :draining
      true -> nil
    end
  end
end
