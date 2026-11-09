defmodule CrewWeb.UsageComponents do
  @moduledoc """
  Usage (§16.6) as the usage page and the box and repo panels show it:
  minutes, shares and reserved hours, and the per-day chart of VM time
  by phase with job minutes over it.
  """
  use Phoenix.Component

  use CrewWeb, :verified_routes

  import CrewWeb.CrewComponents, only: [panel: 1]

  alias CrewWeb.Charts
  alias CrewWeb.Charts.Geometry
  alias CrewWeb.SizingComponents

  @doc "Seconds as whole minutes, with thousands separators."
  def minutes(s), do: s |> Kernel./(60) |> round() |> delimit()

  @doc "A whole number with thousands separators."
  def delimit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "A share as a whole percent, capped at 100, or a dash."
  def pct(nil), do: "–"
  def pct(x), do: "#{round(min(x, 1.0) * 100)}%"

  @doc "`part / whole` as `pct/1` writes it; a dash for nothing."
  def share(_part, whole) when whole in [0, nil], do: "–"
  def share(part, whole), do: pct(part / whole)

  @doc "The overhead of VM time: boot, idle and teardown, as a share."
  def overhead(t), do: share(t.boot_s + t.idle_s + t.teardown_s, t.vm_s)

  @doc "MiB-seconds as GiB-hours, one decimal, whole past 100."
  def gib_h(mib_s), do: hours(mib_s / (1024 * 3600))

  @doc "vCPU-seconds as vCPU-hours, one decimal, whole past 100."
  def vcpu_h(vcpu_s), do: hours(vcpu_s / 3600)

  defp hours(x) when x >= 100, do: x |> round() |> delimit()
  defp hours(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  @doc "A shape as the pages write sizes, named after its size if one matches."
  def shape(%{vcpus: nil}), do: "Unknown size"
  def shape(shape), do: SizingComponents.shape(shape)

  @doc "The days a summary has no stored rollup for yet, in words, or nil."
  def pending([]), do: nil

  def pending(days) do
    n = length(days)

    "#{n} older #{if n == 1, do: "day isn't", else: "days aren't"} counted yet. Crew fills them in every hour."
  end

  @doc "Whether a summary has anything to show."
  def empty?(summary), do: summary.totals.vm_s == 0 and summary.totals.job_count == 0

  attr :id, :string, required: true
  attr :summary, :map, required: true
  attr :title, :string, default: "VM minutes per day"
  attr :class, :any, default: nil

  @doc "VM minutes per UTC day stacked by phase, with job minutes as a line."
  def chart(assigns) do
    series = assigns.summary.series
    point = fn key -> Enum.map(series, &{day_at(&1.day), &1[key] / 60}) end

    [busy, idle, boot, teardown] =
      Geometry.stack([point.(:busy_s), point.(:idle_s), point.(:boot_s), point.(:teardown_s)])

    t = assigns.summary.totals

    lines = [
      %{
        label: "Busy",
        color: Charts.series_color(0),
        kind: :area,
        points: busy,
        value: minutes(t.busy_s)
      },
      %{
        label: "Idle",
        color: Charts.series_color(3),
        kind: :area,
        points: idle,
        value: minutes(t.idle_s)
      },
      %{
        label: "Boot",
        color: Charts.series_color(1),
        kind: :area,
        points: boot,
        value: minutes(t.boot_s)
      },
      %{
        label: "Teardown",
        color: Charts.other_color(),
        kind: :area,
        points: teardown,
        value: minutes(t.teardown_s)
      },
      %{
        label: "Job minutes",
        color: Charts.series_color(6),
        kind: :line,
        points: point.(:job_s),
        value: minutes(t.job_s)
      }
    ]

    top =
      series
      |> Enum.map(&max(&1.vm_s, &1.job_s))
      |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        series: lines,
        since: day_at(assigns.summary.from),
        until: day_at(assigns.summary.to),
        ymax: Geometry.nice_max(top / 60)
      )

    ~H"""
    <Charts.timeseries
      id={@id}
      title={@title}
      note="by phase, with job minutes; UTC days"
      series={@series}
      since={@since}
      until={@until}
      ymax={@ymax}
      gap={86_400}
      days
      format={&format/1}
      empty="No VM time in this range."
      class={@class}
    />
    """
  end

  defp format(x), do: "#{x |> round() |> delimit()} min"

  defp day_at(day), do: day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-xs text-ink-3">{@label}</dt>
      <dd id={@id} class="text-xl font-semibold tabular-nums text-ink">{@value}</dd>
      <dd :if={@note} class="text-xs text-ink-3">{@note}</dd>
    </div>
    """
  end

  attr :summary, :map, required: true

  @doc """
  A box's last 30 days (§17.3): VM minutes by phase, job minutes, use,
  the chart, and its repos by VM minutes, each one the viewer can't
  read named "a private repo", as the page names its VMs' (from a
  `summary/4` with `others: :each`).
  """
  def box_panel(assigns) do
    ~H"""
    <.panel id="usage" title="Usage" class="lg:col-span-2">
      <:subtitle>Last 30 days. Days are UTC.</:subtitle>
      <:actions>
        <.link navigate={~p"/usage"} class="text-xs font-medium text-accent-ink hover:underline">
          All usage
        </.link>
      </:actions>
      <p :if={empty?(@summary)} id="usage-empty" class="text-sm text-ink-3">
        No VMs on this box in the last 30 days.
      </p>
      <div :if={not empty?(@summary)} class="space-y-4">
        <dl class="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-5">
          <.stat
            id="usage-vm-minutes"
            label="VM minutes"
            value={minutes(@summary.totals.vm_s)}
            note={"overhead #{overhead(@summary.totals)}"}
          />
          <.stat
            id="usage-busy"
            label="Busy"
            value={minutes(@summary.totals.busy_s)}
            note={"idle #{minutes(@summary.totals.idle_s)}, boot #{minutes(@summary.totals.boot_s)}, teardown #{minutes(@summary.totals.teardown_s)}"}
          />
          <.stat
            id="usage-job-minutes"
            label="Job minutes"
            value={minutes(@summary.totals.job_s)}
            note={"#{delimit(@summary.totals.job_count)} jobs"}
          />
          <.stat id="usage-mem-use" label="Memory use" value={pct(box_use(@summary, :mem_use))} />
          <.stat id="usage-vcpu-use" label="vCPU use" value={pct(box_use(@summary, :vcpu_use))} />
        </dl>
        <.chart id="usage-chart" summary={@summary} />
        <div>
          <h3 class="mb-1 text-xs font-medium text-ink-2">Repos by VM minutes</h3>
          <ul id="usage-repos" class="divide-y divide-line text-sm">
            <li
              :for={r <- Enum.take(@summary.repos, 5)}
              class="flex items-center justify-between gap-3 py-2"
            >
              <.link
                :if={r.repo}
                navigate={~p"/repos/#{r.repo.id}"}
                class="min-w-0 truncate font-medium text-ink underline-offset-2 hover:underline"
              >
                {r.repo.full_name}
              </.link>
              <span :if={!r.repo} class="min-w-0 truncate text-ink-2">a private repo</span>
              <span class="shrink-0 text-xs tabular-nums text-ink-2">
                {minutes(r.vm_s)} VM min · {minutes(r.job_s)} job min
              </span>
            </li>
          </ul>
        </div>
      </div>
    </.panel>
    """
  end

  defp box_use(%{boxes: [b | _]}, key), do: b[key]
  defp box_use(_summary, _key), do: nil

  attr :summary, :map, required: true
  attr :days, :integer, required: true

  @doc """
  A repo's VM time over the window (§17.3): VM minutes and their
  overhead, and the chart of VM minutes per day by phase with job
  minutes over it. The jobs themselves are the page's insights.
  """
  def repo_panel(assigns) do
    ~H"""
    <.panel id="usage" title="VM time">
      <:subtitle>Last {@days} days. Days are UTC.</:subtitle>
      <:actions>
        <.link navigate={~p"/usage"} class="text-xs font-medium text-accent-ink hover:underline">
          All usage
        </.link>
      </:actions>
      <p :if={empty?(@summary)} id="usage-empty" class="text-sm text-ink-3">
        No VM time in the last {@days} days.
      </p>
      <div :if={not empty?(@summary)} class="space-y-4">
        <dl class="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-4">
          <.stat id="usage-vm-minutes" label="VM minutes" value={minutes(@summary.totals.vm_s)} />
          <.stat
            id="usage-overhead"
            label="Overhead"
            value={overhead(@summary.totals)}
            note="boot, idle and teardown"
          />
          <.stat id="usage-vms" label="VMs" value={delimit(@summary.totals.vm_count)} />
          <.stat
            id="usage-unused"
            label="Unused VMs"
            value={delimit(@summary.totals.unused_count)}
            note="booted, never took a job"
          />
        </dl>
        <.chart id="usage-chart" summary={@summary} />
      </div>
    </.panel>
    """
  end
end
