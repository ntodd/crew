defmodule CrewWeb.UsageComponents do
  @moduledoc """
  Usage (§16.6) as the usage page and the box and repo panels show it:
  minutes, shares and reserved hours, and the per-day chart of VM time
  by phase with job minutes over it.
  """
  use Phoenix.Component

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
end
