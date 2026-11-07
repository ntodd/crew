defmodule CrewWeb.Charts do
  @moduledoc """
  Time-series charts drawn on the server as SVG, with a small hook for
  the crosshair and tooltip.

  A chart has one value axis. Series are `%{label, color, kind, points}`:
  `gap` (optional) overrides the chart's for that series. `kind` is `:line` (`[{at, value}]`) or `:area` (`[{at, lower, upper}]`,
  for stacks; see `Geometry.stack/1`). `color` is a class that sets the
  series hue (`series-1`..`series-8`, `series-other`, `series-accent`):
  production's CSP allows no inline style attributes, so nothing here
  uses one, and the hook positions the tick labels from data attributes. `format` turns a value
  into its label for ticks, the tooltip and the legend.
  """
  use Phoenix.Component

  alias CrewWeb.Charts.Geometry

  @doc "The categorical series colors, in fixed order (see app.css)."
  def series_color(i) when i in 0..7, do: "series-#{i + 1}"
  def other_color, do: "series-other"
  def accent_color, do: "series-accent"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :value, :string, default: nil, doc: "the headline: the latest value"
  attr :note, :string, default: nil, doc: "a line under the headline, like the range's peak"
  attr :series, :list, required: true
  attr :since, :integer, required: true
  attr :until, :integer, required: true
  attr :ymax, :any, required: true
  attr :gap, :integer, required: true, doc: "seconds between samples that still join up"
  attr :format, :any, required: true
  attr :ref, :map, default: nil, doc: "a reference line, %{value, label}"
  attr :legend, :list, default: [], doc: "extra legend rows, %{label, color, value}"
  attr :empty, :string, default: "No samples in this range yet."
  attr :class, :any, default: nil
  attr :plot_class, :any, default: "h-44", doc: "the plot's height"
  slot :summary, doc: "under the headline, over the legend: a meter, say"

  def timeseries(assigns) do
    dom = %{since: assigns.since, until: assigns.until, ymax: assigns.ymax, gap: assigns.gap}

    assigns =
      assigns
      |> assign(:dom, dom)
      |> assign(:y_ticks, y_ticks(assigns.ymax, assigns.format))
      |> assign(:x_ticks, x_ticks(dom))
      |> assign(:empty?, Enum.all?(assigns.series, &(&1.points == [])))
      |> assign(:payload, payload(assigns.series, assigns.format))

    ~H"""
    <figure id={@id} class={["chart rounded-xl border border-line bg-raised shadow-xs", @class]}>
      <figcaption class="flex items-start justify-between gap-4 px-5 pt-4">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-ink">{@title}</h3>
          <p :if={@note} class="mt-0.5 text-xs text-ink-3">{@note}</p>
        </div>
        <p :if={@value} class="chart-value shrink-0 text-2xl font-semibold leading-none text-ink">
          {@value}
        </p>
      </figcaption>

      <div :if={@summary != []} class="mt-3 px-5">{render_slot(@summary)}</div>

      <ul
        :if={length(@series) + length(@legend) > 1}
        class="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 px-5 text-xs"
      >
        <li :for={s <- @series ++ @legend} class="flex min-w-0 items-center gap-1.5">
          <span class={[
            "shrink-0",
            s.color,
            if(Map.get(s, :kind) == :line, do: "chart-key-line", else: "chart-key-area")
          ]} />
          <span class="truncate text-ink-2">{s.label}</span>
          <span :if={v = legend_value(s, @format)} class="tabular-nums font-medium text-ink">{v}</span>
        </li>
      </ul>

      <div
        id={"#{@id}-plot"}
        class={["chart-plot relative mx-5 mt-7", @plot_class]}
        phx-hook=".Chart"
        data-chart={@payload}
        data-since={@since}
        data-until={@until}
        data-gap={@gap}
        tabindex={if(@empty?, do: nil, else: "0")}
        role="img"
        aria-label={"#{@title} over time"}
      >
        <div
          :for={{position, label} <- @y_ticks}
          class={["chart-grid pointer-events-none absolute inset-x-0", position]}
        >
          <span
            :if={label}
            class="chart-tick absolute bottom-0.5 left-0 text-[11px] tabular-nums text-ink-3"
          >
            {label}
          </span>
        </div>

        <svg
          viewBox="0 0 1000 100"
          preserveAspectRatio="none"
          class="absolute inset-0 h-full w-full overflow-visible"
          aria-hidden="true"
        >
          <%= for s <- @series do %>
            <path
              :if={s.kind == :area}
              d={Geometry.area_path(s.points, series_dom(s, @dom))}
              class={["chart-area", s.color]}
            />
          <% end %>
          <line
            :if={@ref}
            x1="0"
            x2="1000"
            y1={Geometry.y(@ref.value, @dom)}
            y2={Geometry.y(@ref.value, @dom)}
            class="chart-ref"
          />
          <%= for s <- @series do %>
            <path
              :if={s.kind == :line}
              d={Geometry.line_path(s.points, series_dom(s, @dom))}
              class={["chart-line", s.color]}
            />
          <% end %>
        </svg>

        <span
          :if={@ref}
          data-top={Geometry.y(@ref.value, @dom)}
          class="chart-tick pointer-events-none absolute right-0 text-[11px] text-ink-3"
        >
          {@ref.label}
        </span>

        <p
          :if={@empty?}
          class="absolute inset-0 flex items-center justify-center text-center text-sm text-ink-3"
        >
          {@empty}
        </p>

        <div data-crosshair class="chart-crosshair pointer-events-none absolute inset-y-0 hidden" />
        <div
          data-tooltip
          class="chart-tooltip pointer-events-none absolute top-2 z-10 hidden min-w-36 rounded-lg border border-line bg-raised px-3 py-2 text-xs shadow-raised"
        />
      </div>

      <div
        id={"#{@id}-ticks"}
        phx-hook=".ChartTicks"
        data-span={@until - @since}
        class="relative mx-5 mb-3 mt-1.5 h-4 text-[11px] tabular-nums text-ink-3"
        aria-hidden="true"
      >
        <time
          :for={at <- @x_ticks}
          data-tick={at}
          data-left={Geometry.x(at, @dom) / 10}
          class="absolute -translate-x-1/2 whitespace-nowrap"
        >
          {DateTime.from_unix!(at) |> Calendar.strftime("%H:%M")}
        </time>
      </div>
    </figure>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Chart">
      // Crosshair and tooltip for a server-drawn chart. The chart's data
      // rides along in data-chart, already formatted, so this only finds
      // the nearest time and shows every series' value there.
      const time = (at, span) => new Intl.DateTimeFormat(undefined,
        span > 86400 ? {weekday: "short", hour: "numeric", minute: "2-digit"}
                     : {hour: "numeric", minute: "2-digit"}).format(new Date(at * 1000))

      export default {
        mounted() {
          this.crosshair = this.el.querySelector("[data-crosshair]")
          this.tooltip = this.el.querySelector("[data-tooltip]")
          this.el.addEventListener("pointermove", e => this.at(this.fromPointer(e)))
          this.el.addEventListener("pointerleave", () => this.hide())
          this.el.addEventListener("blur", () => this.hide())
          this.el.addEventListener("keydown", e => this.key(e))
          this.read()
        },
        updated() {
          this.read()
          if (this.index != null) this.show(Math.min(this.index, this.times.length - 1))
        },
        read() {
          this.data = JSON.parse(this.el.dataset.chart)
          this.since = Number(this.el.dataset.since)
          this.until = Number(this.el.dataset.until)
          const all = new Set()
          for (const s of this.data) for (const p of s.points) all.add(p[0])
          this.times = [...all].sort((a, b) => a - b)
          this.gap = Number(this.el.dataset.gap)
          // Positions are set from script: the CSP allows no inline style
          // attributes, but styles set through the DOM are fine.
          for (const label of this.el.querySelectorAll("[data-top]")) {
            label.style.top = `calc(${label.dataset.top}% - 1.1rem)`
          }
        },
        fromPointer(e) {
          const box = this.el.getBoundingClientRect()
          const at = this.since + (e.clientX - box.left) / box.width * (this.until - this.since)
          return this.nearest(at)
        },
        nearest(at) {
          let best = null, bestGap = Infinity
          this.times.forEach((t, i) => {
            const gap = Math.abs(t - at)
            if (gap < bestGap) { best = i; bestGap = gap }
          })
          return best
        },
        key(e) {
          if (!this.times.length) return
          if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
            e.preventDefault()
            const step = e.key === "ArrowLeft" ? -1 : 1
            const start = this.index ?? this.times.length - 1
            this.at(Math.max(0, Math.min(this.times.length - 1, start + (this.index == null ? 0 : step))))
          } else if (e.key === "Escape") {
            this.hide()
          }
        },
        at(index) { if (index != null) this.show(index) },
        show(index) {
          this.index = index
          const at = this.times[index]
          const pct = (at - this.since) / (this.until - this.since) * 100
          this.crosshair.style.left = pct + "%"
          this.crosshair.classList.remove("hidden")

          const tip = this.tooltip
          tip.replaceChildren()
          const head = document.createElement("p")
          head.className = "mb-1.5 text-ink-3"
          head.textContent = time(at, this.until - this.since)
          tip.append(head)

          this.data.forEach(s => {
            // Each series' nearest sample, if it's close enough to count:
            // VMs can report less often than the box.
            const reach = (s.gap || this.gap) / 2
            let label = null, best = Infinity
            for (const p of s.points) {
              const d = Math.abs(p[0] - at)
              if (d < best && d <= reach) { best = d; label = p[1] }
            }
            if (label == null) return
            const row = document.createElement("p")
            row.className = "flex items-center gap-2"
            const key = document.createElement("span")
            key.className = "chart-key-line " + s.color
            const value = document.createElement("span")
            value.className = "font-semibold tabular-nums text-ink"
            value.textContent = label
            const name = document.createElement("span")
            name.className = "text-ink-2"
            name.textContent = s.label
            row.append(key, value, name)
            tip.append(row)
          })

          tip.classList.remove("hidden")
          const flip = pct > 60
          tip.style.left = flip ? "" : `calc(${pct}% + 12px)`
          tip.style.right = flip ? `calc(${100 - pct}% + 12px)` : ""
        },
        hide() {
          this.index = null
          this.crosshair.classList.add("hidden")
          this.tooltip.classList.add("hidden")
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartTicks">
      // Places a chart's time labels and shows them in the reader's time
      // zone. They get a hook of their own because LiveView only calls
      // updated() when the hooked element differs from the new render, and
      // every live sample resets the labels' text and position.
      const time = (at, span) => new Intl.DateTimeFormat(undefined,
        span > 86400 ? {weekday: "short", hour: "numeric", minute: "2-digit"}
                     : {hour: "numeric", minute: "2-digit"}).format(new Date(at * 1000))

      // On a narrow chart, only every k-th label shows, the smallest k
      // that keeps them apart; a resize thins them again.
      export default {
        mounted() {
          this.place()
          this.resize = new ResizeObserver(() => this.thin())
          this.resize.observe(this.el)
        },
        updated() { this.place() },
        destroyed() { this.resize?.disconnect() },
        place() {
          const span = Number(this.el.dataset.span)
          for (const tick of this.el.querySelectorAll("[data-tick]")) {
            tick.textContent = time(Number(tick.dataset.tick), span)
            tick.style.left = tick.dataset.left + "%"
          }
          this.thin()
        },
        thin() {
          const ticks = [...this.el.querySelectorAll("[data-tick]")]
          const boxes = ticks.map(t => t.getBoundingClientRect())
          const apart = k => boxes.every((b, i) => i < k || i % k || b.left - boxes[i - k].right >= 8)
          let k = 1
          while (k < ticks.length && !apart(k)) k++
          ticks.forEach((t, i) => (t.style.visibility = i % k ? "hidden" : ""))
        }
      }
    </script>
    """
  end

  attr :points, :list, required: true, doc: "[{at, value}]"
  attr :since, :integer, required: true
  attr :until, :integer, required: true
  attr :ymax, :any, required: true
  attr :gap, :integer, required: true
  attr :class, :any, default: nil

  @doc "A small trend line with no axes, for cards."
  def sparkline(assigns) do
    dom = %{since: assigns.since, until: assigns.until, ymax: assigns.ymax, gap: assigns.gap}
    assigns = assign(assigns, :dom, dom)

    ~H"""
    <svg
      viewBox="0 0 1000 100"
      preserveAspectRatio="none"
      class={["block overflow-visible", @class]}
      aria-hidden="true"
    >
      <path
        d={Geometry.area_path(Enum.map(@points, fn {at, v} -> {at, 0, v} end), @dom)}
        class="chart-area series-accent"
      />
      <path
        d={Geometry.line_path(@points, @dom)}
        class="chart-line chart-line-thin series-accent"
      />
    </svg>
    """
  end

  # Ticks whose centred label would run past either edge are dropped.
  defp x_ticks(dom) do
    dom.since
    |> Geometry.time_ticks(dom.until)
    |> Enum.filter(&(Geometry.x(&1, dom) >= 50 and Geometry.x(&1, dom) <= 950))
  end

  # A series sampled less often than the chart (VMs every 30
  # seconds) carries its own gap.
  defp series_dom(%{gap: gap}, dom), do: %{dom | gap: gap}
  defp series_dom(_series, dom), do: dom

  # Gridlines at the baseline, the middle and the top; the baseline goes
  # unlabelled, since every chart here starts at zero.
  defp y_ticks(ymax, format),
    do: [{"top-full", nil}, {"top-1/2", format.(ymax / 2)}, {"top-0", format.(ymax)}]

  defp payload(series, format) do
    series
    |> Enum.map(fn s ->
      points =
        Enum.map(s.points, fn
          {at, v} -> [at, format.(v)]
          {at, lo, hi} -> [at, format.(hi - lo)]
        end)

      %{label: s.label, color: s.color, points: points, gap: Map.get(s, :gap)}
    end)
    |> Jason.encode!()
  end

  defp legend_value(%{value: v}, _format) when is_binary(v), do: v

  defp legend_value(%{points: [_ | _] = points}, format) do
    case List.last(points) do
      {_at, v} -> format.(v)
      {_at, lo, hi} -> format.(hi - lo)
    end
  end

  defp legend_value(_, _), do: nil
end
