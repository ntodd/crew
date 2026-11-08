defmodule CrewWeb.Charts.GeometryTest do
  use ExUnit.Case, async: true

  alias CrewWeb.Charts.Geometry, as: G

  @dom %{since: 0, until: 100, ymax: 50, gap: 30}

  test "maps time to 0-1000 across and values to 100-0 down" do
    assert G.x(0, @dom) == 0.0
    assert G.x(50, @dom) == 500.0
    assert G.y(0, @dom) == 100.0
    assert G.y(25, @dom) == 50.0
    # Values past the top are clamped, not drawn off the plot.
    assert G.y(80, @dom) == 0.0
  end

  test "a line breaks where samples are further apart than the gap" do
    points = [{0, 10}, {10, 10}, {20, 10}, {80, 20}, {90, 20}]
    assert G.runs(points, 30) == [[{0, 10}, {10, 10}, {20, 10}], [{80, 20}, {90, 20}]]

    path = G.line_path(points, @dom)
    assert path == "M0.0,80.0L100.0,80.0L200.0,80.0M800.0,60.0L900.0,60.0"
  end

  test "an area closes down to its lower edge" do
    path = G.area_path([{0, 10, 20}, {20, 10, 30}], @dom)
    assert path == "M0.0,60.0L200.0,40.0L200.0,80.0L0.0,80.0Z"
  end

  test "stacking adds each series onto the ones before it, missing times as zero" do
    a = [{0, 1}, {10, 2}]
    b = [{0, 5}, {20, 1}]

    assert G.stack([a, b]) == [
             [{0, 0, 1}, {10, 0, 2}, {20, 0, 0}],
             [{0, 1, 6}, {10, 2, 2}, {20, 0, 1}]
           ]
  end

  test "nice maximums round up to 1, 2, 2.5 or 5 times a power of ten" do
    assert G.nice_max(0) == 1
    assert G.nice_max(0.7) == 1
    assert G.nice_max(3.2) == 5
    assert G.nice_max(17) == 20
    assert G.nice_max(2_100) == 2_500
    assert G.nice_max(6_100) == 10_000
  end

  test "time ticks fall on round intervals, at most seven across the range" do
    # An hour: ticks every 10 minutes.
    until = 1_760_530_050
    ticks = G.time_ticks(until - 3_600, until)
    assert Enum.all?(ticks, &(rem(&1, 600) == 0))
    assert length(ticks) == 6

    week = G.time_ticks(until - 7 * 86_400, until)
    assert length(week) in 6..8
  end

  test "day ticks fall on UTC days, at most seven, the last on the range's end" do
    # 2026-11-08 00:00 UTC
    until = 1_794_096_000

    for days <- [7, 30, 90] do
      ticks = G.day_ticks(until - (days - 1) * 86_400, until)
      assert Enum.all?(ticks, &(rem(&1, 86_400) == 0))
      assert length(ticks) <= 7
      assert List.last(ticks) == until
    end

    assert length(G.day_ticks(until - 6 * 86_400, until)) == 7
  end
end
