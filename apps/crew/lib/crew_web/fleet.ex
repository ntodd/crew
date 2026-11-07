defmodule CrewWeb.Fleet do
  @moduledoc """
  The fleet at a glance, for the Boxes page (§17.3): each box's usage
  and what its VMs hold of what it offers, over a range; the totals; the
  vCPUs and memory provisioned over time, stacked by box; and the boxes
  that can't take jobs for a problem.

  Capacity counts the online boxes (an offline box offers nothing);
  what's provisioned counts every VM not yet destroyed, wherever it is,
  as placement does (§8.3).

  `load/2` reads everything; `refresh/1` only what moves when a VM or a
  box changes (states, allocations, issues), so a busy fleet doesn't
  re-read its charts on every VM transition.
  """

  alias Crew.{Agents, Boxes, Metrics, Scheduler, Sizes, VMs}
  alias CrewWeb.Charts

  # A range, its seconds; each is drawn in at most ~240 points of 5 s
  # multiples, as Foreman's charts are.
  @ranges [{"30m", 1_800}, {"1h", 3_600}, {"6h", 21_600}, {"24h", 86_400}]
  @points 240

  def ranges, do: Enum.map(@ranges, &elem(&1, 0))

  @doc "The fleet over `range` (one of `ranges/0`; anything else is the first) ending at `now`."
  def load(range, now \\ System.os_time(:second)) do
    {range, seconds} = List.keyfind(@ranges, range, 0) || hd(@ranges)
    step = max(5, ceil(seconds / @points / 5) * 5)
    since = now - seconds

    %{range: range, since: since, until: now, step: step}
    |> Map.put(:sizes, Map.new(Sizes.list(), &{&1.id, &1.name}))
    |> read(Boxes.list(), MapSet.new(Agents.online_ids()))
    |> charts()
  end

  @doc """
  Re-reads the boxes and their VMs, keeping the charts; or, when a box
  came, went, joined or left, everything: the charts have a band per
  online box, and the cards' colours and the bands' must match.
  """
  def refresh(fleet) do
    boxes = Boxes.list()
    online = MapSet.new(Agents.online_ids())
    before = MapSet.new(fleet.boxes, &{&1.box.id, &1.online})
    now = MapSet.new(boxes, &{&1.id, MapSet.member?(online, &1.id)})

    if before == now,
      do: read(fleet, boxes, online),
      else: load(fleet.range, fleet.until)
  end

  defp read(fleet, boxes, online) do
    vms = Enum.group_by(VMs.list_live(), & &1.box_id)
    colors = colors(boxes)

    entries =
      Enum.map(boxes, fn box ->
        box_vms = Map.get(vms, box.id, [])
        online? = MapSet.member?(online, box.id)

        %{
          box: box,
          online: online?,
          color: colors[box.id],
          issues: Boxes.issues(box, online?),
          latest: fresh(Metrics.latest_box(box.id), fleet.until),
          series: get_in(fleet, [:boxes_series, box.id]) || [],
          allocation: VMs.allocation_of(box_vms),
          capacity: Scheduler.capacity(box),
          vms: vm_states(box_vms),
          sizes: sizes(box_vms, fleet.sizes)
        }
      end)

    fleet
    |> Map.put(:boxes, entries)
    |> Map.put(:totals, totals(entries, vms))
    |> Map.put(:attention, Enum.filter(entries, &attention?/1))
  end

  # The charts: each box's samples, and what's provisioned, stacked by box.
  defp charts(fleet) do
    series =
      Map.new(fleet.boxes, &{&1.box.id, Metrics.box_series(&1.box.id, fleet.since, fleet.step)})

    held = VMs.provisioned_series(fleet.since, fleet.until, fleet.step)

    # Every online box gets a band, and any box that held VMs in the
    # range, revoked ones too: revoking a box doesn't rewrite the past.
    current = MapSet.new(fleet.boxes, & &1.box.id)

    revoked =
      for id <- Map.keys(held), not MapSet.member?(current, id), box = Boxes.get(id) do
        %{box: box, color: Charts.other_color()}
      end

    shown =
      Enum.filter(fleet.boxes, &(&1.online or Map.has_key?(held, &1.box.id))) ++
        Enum.sort_by(revoked, & &1.box.name)

    zeros = Enum.map(VMs.series_ticks(fleet.since, fleet.until, fleet.step), &{&1, 0, 0})

    stack = fn pick ->
      bands =
        shown
        |> Enum.map(fn e ->
          Enum.map(Map.get(held, e.box.id, zeros), &{elem(&1, 0), pick.(&1)})
        end)
        |> Charts.Geometry.stack()

      Enum.zip_with(shown, bands, fn e, points ->
        %{label: e.box.name, kind: :area, color: e.color, points: points}
      end)
    end

    fleet
    |> Map.put(:boxes, Enum.map(fleet.boxes, &%{&1 | series: series[&1.box.id]}))
    |> Map.put(:boxes_series, series)
    |> Map.put(:provisioned, %{
      vcpus: stack.(&elem(&1, 1)),
      memory: stack.(&(elem(&1, 2) / 1024))
    })
  end

  # A box reports every 5 s: a sample a minute old isn't how it is now.
  defp fresh(%{t: t} = sample, now) when t >= now - 60, do: sample
  defp fresh(_sample, _now), do: nil

  # A box's colour follows it, not its rank: boxes take colours in the
  # order they were added, so a new box takes the next one whatever its
  # name. Past eight, they share "other".
  defp colors(boxes) do
    boxes
    |> Enum.sort_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.with_index()
    |> Map.new(fn {box, i} -> {box.id, color(i)} end)
  end

  defp color(i) when i < 8, do: Charts.series_color(i)
  defp color(_), do: Charts.other_color()

  defp totals(entries, vms) do
    capacity = Enum.filter(entries, &(&1.online and &1.box.pinned_capabilities != nil))
    caps = fn key -> Enum.sum_by(capacity, &(&1.box.pinned_capabilities[key] || 0)) end
    held = vms |> Map.values() |> List.flatten() |> VMs.allocation_of()

    %{
      boxes: length(entries),
      online: Enum.count(entries, & &1.online),
      draining: Enum.count(entries, &(:draining in &1.issues and not attention?(&1))),
      cores: caps.("vcpus"),
      cores_by_arch: cores_by_arch(capacity),
      memory_mib: caps.("memory_mib"),
      allocatable_vcpus: Enum.sum_by(capacity, &((&1.capacity && &1.capacity.vcpus) || 0)),
      allocatable_memory_mib:
        Enum.sum_by(capacity, &((&1.capacity && &1.capacity.memory_mib) || 0)),
      provisioned_vcpus: held.vcpus,
      provisioned_memory_mib: held.memory_mib,
      vms: vms |> Map.values() |> List.flatten() |> vm_states()
    }
  end

  # The cores job VMs of each arch can have, most first.
  defp cores_by_arch(entries) do
    entries
    |> Enum.group_by(
      &(&1.box.guest_arch || &1.box.pinned_capabilities["guest_arch"] || "unknown"),
      &(&1.box.pinned_capabilities["vcpus"] || 0)
    )
    |> Enum.map(fn {arch, cores} -> {arch, Enum.sum(cores)} end)
    |> Enum.sort_by(fn {arch, n} -> {-n, arch} end)
  end

  # VMs by where they are in their life (§8.6): booting, idle (waiting
  # for a job), busy (running one), ending (finished or failed, not yet
  # destroyed).
  defp vm_states(vms) do
    counts =
      Enum.frequencies_by(vms, fn vm ->
        case vm.state do
          "busy" -> :busy
          "idle" -> :idle
          s when s in ~w(requested starting booted) -> :booting
          _ -> :ending
        end
      end)

    Map.merge(%{busy: 0, idle: 0, booting: 0, ending: 0}, counts)
    |> Map.put(:total, length(vms))
  end

  defp sizes(vms, names) do
    vms
    |> Enum.frequencies_by(&Map.get(names, &1.size_id, "#{&1.vcpus}c"))
    |> Enum.sort_by(fn {name, n} -> {-n, name} end)
  end

  # A box that can't take jobs for a problem; a drain is on purpose.
  defp attention?(%{issues: issues}),
    do: Enum.any?(issues, &(Boxes.blocking?(&1) and &1 != :draining))
end
