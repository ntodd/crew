defmodule CrewWeb.BoxLive.Index do
  @moduledoc """
  Boxes (§17.3): the fleet's totals and what its VMs hold of it over
  time, then a card per box with its status and any problem that keeps
  jobs off it, its CPU and memory over the range, and what its VMs hold
  of what it offers.

  Live: the charts every 5 s (a box reports every 5 s), and the rest as
  boxes and VMs change.
  """
  use CrewWeb, :live_view

  alias Crew.{Boxes, Scope, VMs}
  alias CrewWeb.{Charts, Fleet}
  alias CrewWeb.Charts.Geometry

  @tick_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Boxes.subscribe()
      VMs.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, assign(socket, :page_title, "Boxes")}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, :fleet, Fleet.load(params["range"] || "30m"))}

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign(socket, :fleet, Fleet.load(socket.assigns.fleet.range))}
  end

  # States and allocations move with every VM transition: those at once,
  # the charts on the next tick.
  def handle_info({event, _id}, socket) when event in [:box_changed, :vm_changed],
    do: {:noreply, update(socket, :fleet, &Fleet.refresh/1)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb>Boxes</:breadcrumb>
      <.header>
        Boxes
        <:subtitle>The machines that run job VMs.</:subtitle>
        <:actions>
          <span
            :if={@fleet.boxes != []}
            class="mr-1 inline-flex items-center gap-1.5 text-xs text-ink-3"
            title="Charts update every 5 seconds"
          >
            <span class="size-1.5 rounded-full bg-success motion-safe:animate-status-pulse" /> Live
          </span>
          <span :if={@fleet.boxes != []} class="segmented" role="group" aria-label="Time range">
            <.link
              :for={range <- Fleet.ranges()}
              id={"range-#{range}"}
              patch={~p"/boxes?range=#{range}"}
              aria-current={to_string(range == @fleet.range)}
            >
              {range}
            </.link>
          </span>
          <.button
            :if={Scope.admin?(@current_scope)}
            navigate={~p"/boxes/new"}
            variant="primary"
            size="sm"
            icon="hero-plus"
          >
            Add box
          </.button>
        </:actions>
      </.header>

      <.callout
        :if={@fleet.attention != []}
        id="boxes-attention"
        kind="danger"
        icon="hero-exclamation-triangle-mini"
      >
        <p class="font-medium">
          {length(@fleet.attention)} {if length(@fleet.attention) == 1, do: "box", else: "boxes"} can't take jobs
        </p>
        <ul class="mt-1 space-y-0.5">
          <li :for={entry <- @fleet.attention}>
            <.link
              navigate={~p"/boxes/#{entry.box.id}"}
              class="font-medium underline"
            >{entry.box.name}</.link>: {why(entry)}
          </li>
        </ul>
      </.callout>

      <section :if={@fleet.boxes != []} id="fleet" aria-label="Fleet" class="@container space-y-4">
        <.totals totals={@fleet.totals} attention={length(@fleet.attention)} />
        <div class="grid gap-4 @5xl:grid-cols-2">
          <.provisioned
            id="provisioned-vcpus"
            title="vCPUs provisioned"
            of="online vCPUs"
            fleet={@fleet}
            series={@fleet.provisioned.vcpus}
            held={@fleet.totals.provisioned_vcpus}
            offered={trunc(@fleet.totals.allocatable_vcpus)}
            number={&count/1}
            format={&count/1}
          />
          <.provisioned
            id="provisioned-memory"
            title="Memory provisioned"
            of="online memory"
            fleet={@fleet}
            series={@fleet.provisioned.memory}
            held={@fleet.totals.provisioned_memory_mib / 1024}
            offered={@fleet.totals.allocatable_memory_mib / 1024}
            number={&gib_number/1}
            unit=" GiB"
            format={&gib_label/1}
          />
        </div>
      </section>

      <section :if={@fleet.boxes != []} aria-label="Boxes" class="@container">
        <div id="boxes-grid" class={["grid gap-4", grid_cols(length(@fleet.boxes))]}>
          <.box_card :for={entry <- @fleet.boxes} entry={entry} fleet={@fleet} />
        </div>
      </section>

      <.panel :if={@fleet.boxes == []}>
        <.empty_state id="boxes-empty" icon="hero-server-stack" title="Add your first box">
          A box is a machine that runs job VMs: a Mac with Virtualization.framework, or Linux with KVM.
          <:action :if={Scope.admin?(@current_scope)}>
            <.button navigate={~p"/boxes/new"} size="sm" variant="primary">Add box</.button>
          </:action>
        </.empty_state>
      </.panel>
    </Layouts.app>
    """
  end

  # -- the fleet ----------------------------------------------------------------------

  attr :totals, :map, required: true
  attr :attention, :integer, required: true

  defp totals(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 @4xl:grid-cols-4">
      <.stat id="fleet-boxes" label="Boxes online">
        {@totals.online} <span class="text-base font-medium text-ink-3">of {@totals.boxes}</span>
        <:note>
          <span :if={@attention > 0} class="inline-flex items-center gap-1 text-danger">
            <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
            {@attention} can't take jobs
          </span>
          <span :if={@attention == 0 and @totals.draining > 0}>{@totals.draining} draining</span>
          <span
            :if={@attention == 0 and @totals.draining == 0}
            class="inline-flex items-center gap-1 text-success"
          >
            <.icon name="hero-check-circle-micro" class="size-3.5" /> All taking jobs
          </span>
        </:note>
      </.stat>
      <.stat id="fleet-cores" label="Cores">
        {@totals.cores}
        <:note>For job VMs, on the online boxes</:note>
      </.stat>
      <.stat id="fleet-memory" label="Memory">
        {gib(@totals.memory_mib)} <span class="text-base font-medium text-ink-3">GiB</span>
        <:note>For job VMs, on the online boxes</:note>
      </.stat>
      <.stat id="fleet-vms" label="VMs">
        {@totals.vms.total}
        <:note>{vm_states(@totals.vms)}</:note>
      </.stat>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :note

  defp stat(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-line bg-raised px-4 py-3.5 shadow-xs">
      <p class="text-xs font-medium text-ink-2">{@label}</p>
      <p class="mt-1.5 text-2xl font-semibold leading-none tabular-nums text-ink">
        {render_slot(@inner_block)}
      </p>
      <p :if={@note != []} class="mt-2 text-xs text-ink-3">{render_slot(@note)}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :fleet, :map, required: true
  attr :series, :list, required: true
  attr :held, :any, required: true
  attr :offered, :any, required: true
  attr :number, :any, required: true, doc: "the headline's numbers"
  attr :unit, :string, default: ""
  attr :of, :string, required: true, doc: "what the share is of, for the note"
  attr :format, :any, required: true, doc: "a value on the chart, with its unit"

  defp provisioned(assigns) do
    peak =
      assigns.series
      |> List.last(%{points: []})
      |> Map.fetch!(:points)
      |> Enum.map(&elem(&1, 2))
      |> Enum.max(fn -> 0 end)

    total =
      case List.last(assigns.series) do
        %{points: points} ->
          [
            %{
              label: "Total",
              kind: :line,
              color: Charts.accent_color(),
              points: Enum.map(points, fn {t, _lo, hi} -> {t, hi} end)
            }
          ]

        nil ->
          []
      end

    assigns =
      assign(assigns,
        series: assigns.series ++ total,
        ymax: headroom(max(assigns.offered, peak)),
        ratio: if(assigns.offered > 0, do: assigns.held / assigns.offered, else: 0)
      )

    ~H"""
    <Charts.timeseries
      id={@id}
      title={@title}
      value={"#{@number.(@held)} / #{@number.(@offered)}#{@unit}"}
      note={"#{round(@ratio * 100)}% of #{@of}"}
      series={@series}
      since={@fleet.since}
      until={@fleet.until}
      ymax={@ymax}
      gap={@fleet.step * 3}
      format={@format}
      ref={@offered > 0 && %{value: @offered, label: "#{@format.(@offered)} offered"}}
      plot_class="h-40"
      empty="No boxes online."
    >
      <:summary>
        <progress
          class={["bar", meter_class(@ratio)]}
          value={round(min(@held, @offered) * 100)}
          max={max(round(@offered * 100), 1)}
          aria-label={@title}
        >
          {round(@ratio * 100)}%
        </progress>
      </:summary>
    </Charts.timeseries>
    """
  end

  # Room over the larger of the capacity and the peak, in round steps.
  defp headroom(v) when v <= 0, do: 1

  defp headroom(v) do
    step = Geometry.nice_max(v) / 10
    trunc(Float.ceil(v * 1.1 / step) * step)
  end

  defp meter_class(ratio) when ratio > 1, do: "bar-danger"
  defp meter_class(ratio) when ratio > 0.9, do: "bar-warning"
  defp meter_class(_), do: nil

  defp why(%{issues: issues, box: box}) do
    issue = Enum.find(issues, &(Boxes.blocking?(&1) and &1 != :draining))
    {title, _} = box_issue(issue, box)
    String.downcase(title)
  end

  # -- a box ---------------------------------------------------------------------------

  # Three or four boxes fill a row on a wide screen; one or two get wider
  # cards, which lay out their charts beside what's provisioned.
  defp grid_cols(1), do: "grid-cols-1"
  defp grid_cols(2), do: "grid-cols-1 @3xl:grid-cols-2"
  defp grid_cols(3), do: "grid-cols-1 @2xl:grid-cols-2 @5xl:grid-cols-3"
  defp grid_cols(4), do: "grid-cols-1 @2xl:grid-cols-2 @7xl:grid-cols-4"
  defp grid_cols(_), do: "grid-cols-1 @2xl:grid-cols-2 @5xl:grid-cols-3 @[100rem]:grid-cols-4"

  attr :entry, :map, required: true
  attr :fleet, :map, required: true

  defp box_card(assigns) do
    %{entry: e} = assigns
    caps = e.box.pinned_capabilities || %{}

    assigns =
      assign(assigns,
        id: "box-#{e.box.id}",
        caps: caps,
        alerts: for(i <- e.issues, alert?(i), do: {i, box_issue(i, e.box)}),
        mem_total: (e.latest && e.latest.mem_total_mib) || caps["memory_mib"]
      )

    ~H"""
    <.link
      navigate={~p"/boxes/#{@entry.box.id}"}
      id={@id}
      class="@container flex flex-col rounded-xl border border-line bg-raised shadow-xs transition-colors hover:border-line-strong"
    >
      <div class="flex items-start justify-between gap-3 px-5 pt-4">
        <div class="min-w-0">
          <p class="flex items-center gap-2">
            <span class={["chart-key-area shrink-0", @entry.color]} aria-hidden="true" />
            <span class="truncate font-semibold text-ink">{@entry.box.name}</span>
          </p>
          <p class="mt-0.5 text-xs text-ink-3">
            {@entry.box.type} · {@entry.box.driver || "no driver yet"} · {@entry.box.guest_arch || "?"} · agent {@entry.box.agent_version ||
              "?"}
          </p>
        </div>
        <.box_status box={@entry.box} online={@entry.online} />
      </div>

      <ul
        :if={@alerts != []}
        id={"#{@id}-issues"}
        class="mx-5 mt-3 space-y-1.5 rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger"
      >
        <li :for={{issue, {title, detail}} <- @alerts} class="flex gap-2">
          <.icon
            name={if issue == :sleep_on, do: "hero-moon-micro", else: "hero-no-symbol-micro"}
            class="mt-px size-3.5 shrink-0"
          />
          <span><span class="font-semibold">{title}.</span> {detail}</span>
        </li>
      </ul>

      <div class="grid flex-1 content-start gap-x-8 gap-y-4 px-5 py-4 @3xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div class="grid grid-cols-2 gap-4">
          <div id={"#{@id}-cpu"}>
            <p class="flex items-baseline justify-between gap-2 text-xs">
              <span class="text-ink-2">CPU</span>
              <span class="font-semibold tabular-nums text-ink">
                {if @entry.latest, do: "#{round(@entry.latest.cpu_pct)}%", else: "–"}
              </span>
            </p>
            <.trend
              points={Enum.map(@entry.series, &{&1.t, &1.cpu_pct})}
              ymax={100}
              fleet={@fleet}
            />
          </div>
          <div id={"#{@id}-memory"}>
            <p class="flex items-baseline justify-between gap-2 text-xs">
              <span class="text-ink-2">Memory</span>
              <span class="truncate font-semibold tabular-nums text-ink">
                <%= if @entry.latest do %>
                  {gib(@entry.latest.mem_used_mib)}
                  <span class="font-normal text-ink-3">of {gib(@entry.latest.mem_total_mib)} GiB</span>
                <% else %>
                  –
                <% end %>
              </span>
            </p>
            <.trend
              points={Enum.map(@entry.series, &{&1.t, &1.mem_used_mib})}
              ymax={@mem_total}
              fleet={@fleet}
            />
          </div>
        </div>

        <div class="space-y-3">
          <%= if @entry.capacity do %>
            <div id={"#{@id}-vcpus"}>
              <.capacity_bar
                label="vCPUs provisioned"
                value={@entry.allocation.vcpus}
                max={trunc(@entry.capacity.vcpus)}
              />
            </div>
            <div id={"#{@id}-mem-provisioned"}>
              <.capacity_bar
                label="Memory provisioned"
                value={@entry.allocation.memory_mib}
                max={@entry.capacity.memory_mib}
                format={&gib/1}
                unit=" GiB"
              />
            </div>
          <% else %>
            <p class="text-xs text-ink-3">No capacity until the agent reports.</p>
          <% end %>
          <p id={"#{@id}-vms"} class="flex flex-wrap justify-between gap-x-3 gap-y-0.5 text-xs">
            <span class="text-ink-2">{vm_summary(@entry.vms)}</span>
            <span :if={@entry.sizes != []} class="text-ink-3">
              {Enum.map_join(@entry.sizes, " · ", fn {name, n} -> "#{n} × #{name}" end)}
            </span>
          </p>
        </div>
      </div>

      <p
        :if={@caps != %{}}
        class="border-t border-line px-5 py-2.5 text-xs text-ink-3"
      >
        {@caps["vcpus"]} cores · {gib(@caps["memory_mib"])} GiB for VMs · {overcommit(@entry.box)} CPU overcommit<span :if={
          @entry.latest
        }> · {gib(@entry.latest.vm_area_free_mib)} GiB clone area free · load {load(
          @entry.latest.load1
        )}</span>
      </p>
    </.link>
    """
  end

  attr :points, :list, required: true
  attr :ymax, :any, required: true
  attr :fleet, :map, required: true

  defp trend(assigns) do
    ~H"""
    <div class="relative mt-2 h-12 @3xl:h-20">
      <Charts.sparkline
        :if={@points != []}
        points={@points}
        since={@fleet.since}
        until={@fleet.until}
        ymax={@ymax || 1}
        gap={@fleet.step * 3}
        class="h-full w-full"
      />
      <p
        :if={@points == []}
        class="flex h-full items-center justify-center rounded-md border border-dashed border-line text-[11px] text-ink-3"
      >
        No samples in this range
      </p>
    </div>
    """
  end

  # On the card: what keeps jobs off the box (a drain is on purpose, and
  # its badge says so), and sleep, which pauses them.
  defp alert?(issue), do: (Boxes.blocking?(issue) and issue != :draining) or issue == :sleep_on

  # -- words and numbers ----------------------------------------------------------------

  defp vm_summary(%{total: 0}), do: "No VMs"

  defp vm_summary(vms),
    do: "#{vms.total} #{if vms.total == 1, do: "VM", else: "VMs"} · #{vm_states(vms)}"

  defp vm_states(%{total: 0}), do: "None running"

  defp vm_states(vms) do
    [
      vms.busy > 0 && "#{vms.busy} running #{if vms.busy == 1, do: "a job", else: "jobs"}",
      vms.booting > 0 && "#{vms.booting} booting",
      vms.idle > 0 && "#{vms.idle} idle",
      vms.ending > 0 && "#{vms.ending} finishing"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp count(v), do: Integer.to_string(round(v))

  # GiB in, to one decimal below 100.
  defp gib_number(v) when v >= 100, do: Integer.to_string(round(v))
  defp gib_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 1)
  defp gib_label(v), do: "#{gib_number(v)} GiB"

  defp load(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)

  defp overcommit(box),
    do: "#{:erlang.float_to_binary((box.cpu_overcommit || 1.5) * 1.0, [:short])}×"
end
