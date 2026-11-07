defmodule Crew.MetricsTest do
  @moduledoc "Reading box samples back for charts (§16.5)."
  use Crew.DataCase

  alias Crew.Metrics

  describe "box_series/3" do
    test "averages a box's samples over each step, oldest first" do
      box = box_fixture()
      other = box_fixture()
      since = 1_800_000_000

      box_metric_fixture(box, since + 1, cpu_pct: 10.0, mem_used_mib: 1000, load1: 1.0)
      box_metric_fixture(box, since + 6, cpu_pct: 30.0, mem_used_mib: 3000, load1: 3.0)
      box_metric_fixture(box, since + 11, cpu_pct: 50.0, mem_used_mib: 5000, load1: 5.0)
      box_metric_fixture(other, since + 1, cpu_pct: 99.0)

      assert [first, second] = Metrics.box_series(box.id, since, 10)

      assert %{t: ^since, cpu_pct: 20.0, mem_used_mib: 2000, mem_total_mib: 131_072, load1: 2.0} =
               first

      assert %{t: t, cpu_pct: 50.0, mem_used_mib: 5000} = second
      assert t == since + 10
    end

    test "starts at `since`, not the start of the bucket it falls in" do
      box = box_fixture()
      since = 1_800_000_005
      box_metric_fixture(box, since + 1, cpu_pct: 40.0)
      box_metric_fixture(box, since - 1, cpu_pct: 90.0)

      assert [%{t: ^since, cpu_pct: 40.0}] = Metrics.box_series(box.id, since, 10)
    end
  end
end
