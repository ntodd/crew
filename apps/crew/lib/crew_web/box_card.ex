defmodule CrewWeb.BoxCard do
  @moduledoc """
  A box at a glance: its status, its last half hour of CPU and memory,
  what its VMs hold of what it offers job VMs, and its VMs by size. The
  dashboard's fleet strip is a row of these, and the run page shows one
  when you hover the box a job ran on.
  """
  use Phoenix.Component

  import CrewWeb.CrewComponents

  alias Crew.{Agents, Metrics, Scheduler, VMs}
  alias CrewWeb.Charts

  @window_s 1800

  @doc "What the card shows of `box`, as of now."
  def load(box) do
    vms = VMs.for_box(box.id)
    until = System.os_time(:second)

    %{
      box: box,
      online: Agents.online?(box.id),
      series: Metrics.box_series(box.id, until - @window_s),
      since: until - @window_s,
      until: until,
      allocation: VMs.allocation_of(vms),
      capacity: Scheduler.capacity(box),
      by_size: vms |> Enum.frequencies_by(&{&1.vcpus, &1.memory_mib}) |> Enum.sort()
    }
  end

  @doc "The card in a sentence, for a screen reader: what the box is running, of what."
  def summary(%{box: box, online: online, allocation: a, capacity: cap}) do
    vms = "#{a.count} #{if a.count == 1, do: "VM", else: "VMs"}"

    held =
      if cap,
        do:
          ", #{round(a.memory_mib / 1024)} of #{round(cap.memory_mib / 1024)} GiB and " <>
            "#{a.vcpus} of #{trunc(cap.vcpus)} vCPUs allocated",
        else: ""

    "#{box.name}: #{if online, do: "online", else: "offline"}, #{vms}#{held}"
  end

  attr :card, :map, required: true

  def box_card(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-x-2 gap-y-1">
      <span class="min-w-0 truncate font-medium text-ink">{@card.box.name}</span>
      <.box_status box={@card.box} online={@card.online} />
    </div>
    <div class="mt-3 grid grid-cols-2 gap-3">
      <div>
        <p class="text-xs text-ink-3">CPU</p>
        <Charts.sparkline
          points={pct(@card.series, :cpu_pct)}
          since={@card.since}
          until={@card.until}
          ymax={100}
          gap={30}
        />
      </div>
      <div>
        <p class="text-xs text-ink-3">Memory</p>
        <Charts.sparkline
          points={pct(@card.series, :mem_used_mib, :mem_total_mib)}
          since={@card.since}
          until={@card.until}
          ymax={100}
          gap={30}
        />
      </div>
    </div>
    <div :if={@card.capacity} class="mt-3 space-y-2">
      <.capacity_bar
        label="vCPUs"
        value={@card.allocation.vcpus}
        max={trunc(@card.capacity.vcpus)}
      />
      <.capacity_bar
        label="Memory (GiB)"
        value={round(@card.allocation.memory_mib / 1024)}
        max={round(@card.capacity.memory_mib / 1024)}
      />
    </div>
    <p class="mt-2 text-xs text-ink-3">
      {@card.allocation.count} {if @card.allocation.count == 1, do: "VM", else: "VMs"}<span :for={
        {{vcpus, mem}, n} <- @card.by_size
      }> · {n} × {vcpus}c/{gib(mem)}G</span>
    </p>
    """
  end

  defp pct(points, field, total_field \\ nil) do
    Enum.map(points, fn m ->
      v = Map.fetch!(m, field)
      if total_field, do: {m.t, v * 100 / max(Map.fetch!(m, total_field), 1)}, else: {m.t, v}
    end)
  end
end
