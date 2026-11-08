defmodule CrewWeb.Charts.Geometry do
  @moduledoc """
  Plot geometry for the time-series charts. Paths are drawn in a
  1000 x 100 box (time across, value down from the top) that the SVG
  stretches to fit, with non-scaling strokes so lines stay 2px.

  `dom` is `%{since, until, ymax, gap}`: the time range in Unix seconds,
  the value at the top of the plot, and the longest pause between samples
  that still draws as a continuous line (longer reads as no data).
  """

  @width 1000
  @height 100
  @day_intervals [1, 2, 7, 14, 28]
  @tick_intervals [300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400]

  def x(at, %{since: since, until: until}) when until > since,
    do: Float.round((at - since) / (until - since) * @width, 1)

  # An empty range has nowhere to put anything but the left edge.
  def x(_at, _dom), do: 0.0

  def y(v, %{ymax: ymax}) when ymax > 0,
    do: Float.round(@height - min(max(v / ymax, 0.0), 1.0) * @height, 1)

  # No scale (a total the box couldn't read): draw on the baseline.
  def y(_v, _dom), do: @height * 1.0

  @doc "Splits points into runs wherever consecutive samples are more than `gap` apart."
  def runs([], _gap), do: []

  def runs(points, gap) do
    points
    |> Enum.chunk_while(
      [],
      fn
        p, [] ->
          {:cont, [p]}

        p, [prev | _] = acc when elem(p, 0) - elem(prev, 0) > gap ->
          {:cont, Enum.reverse(acc), [p]}

        p, acc ->
          {:cont, [p | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
  end

  @doc "An SVG path for `[{at, value}]`, broken at gaps."
  def line_path(points, dom) do
    points
    |> runs(dom.gap)
    |> Enum.map_join(fn run ->
      run
      |> Enum.with_index()
      |> Enum.map_join(fn {{at, v}, i} ->
        "#{if i == 0, do: "M", else: "L"}#{x(at, dom)},#{y(v, dom)}"
      end)
    end)
  end

  @doc "A closed SVG path for a band `[{at, lower, upper}]`, broken at gaps."
  def area_path(points, dom) do
    points
    |> runs(dom.gap)
    |> Enum.map_join(fn run ->
      top = Enum.map(run, fn {at, _lo, hi} -> "#{x(at, dom)},#{y(hi, dom)}" end)

      bottom =
        run |> Enum.reverse() |> Enum.map(fn {at, lo, _hi} -> "#{x(at, dom)},#{y(lo, dom)}" end)

      "M" <> Enum.join(top ++ bottom, "L") <> "Z"
    end)
  end

  @doc """
  Stacks series of `[{at, value}]` in order: each becomes `[{at, lower,
  upper}]` sitting on the ones before it. A series with no sample at a
  time counts as zero there.
  """
  def stack(series) do
    ats =
      series |> Enum.flat_map(fn s -> Enum.map(s, &elem(&1, 0)) end) |> Enum.uniq() |> Enum.sort()

    base = Map.new(ats, &{&1, 0})

    {stacked, _} =
      Enum.map_reduce(series, base, fn s, floor ->
        values = Map.new(s)

        band =
          Enum.map(ats, fn at ->
            lo = floor[at]
            {at, lo, lo + Map.get(values, at, 0)}
          end)

        {band, Map.new(band, fn {at, _lo, hi} -> {at, hi} end)}
      end)

    stacked
  end

  @doc "The smallest of 1, 2, 2.5 or 5 times a power of ten at or above `v`."
  def nice_max(v) when v <= 0, do: 1

  def nice_max(v) do
    magnitude = :math.pow(10, Float.floor(:math.log10(v)))

    [1, 2, 2.5, 5, 10]
    |> Enum.map(&(&1 * magnitude))
    |> Enum.find(&(&1 >= v))
    |> then(fn n -> if n == trunc(n), do: trunc(n), else: n end)
  end

  @doc "Round tick times inside the range, at most seven of them."
  def time_ticks(since, until) do
    span = until - since
    interval = Enum.find(@tick_intervals, List.last(@tick_intervals), &(span / &1 <= 7))
    first = since + interval - rem(since, interval)
    Enum.to_list(first..until//interval)
  end

  @doc """
  Ticks for a chart of UTC days (points at each day's start): every 1,
  2, 7, 14 or 28 days, at most seven, counted back from `until`.
  """
  def day_ticks(since, until) do
    days = div(until - since, 86_400) + 1
    step = Enum.find(@day_intervals, List.last(@day_intervals), &(ceil(days / &1) <= 7)) * 86_400
    until |> Stream.iterate(&(&1 - step)) |> Enum.take_while(&(&1 >= since)) |> Enum.reverse()
  end
end
