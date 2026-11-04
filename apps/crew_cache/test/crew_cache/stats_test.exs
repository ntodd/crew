defmodule CrewCache.StatsTest do
  use ExUnit.Case, async: false

  alias CrewCache.Stats

  setup do
    start_supervised!(Stats)
    :ok
  end

  test "counts per host" do
    Stats.hit("ghcr.io", "actions/runner")
    Stats.hit("ghcr.io", "actions/runner")
    Stats.miss("ghcr.io", "actions/runner")
    Stats.served("ghcr.io", "actions/runner", 100)
    Stats.mismatch("ghcr.io")
    Stats.evicted(3)

    snap = Stats.snapshot()
    assert snap.hosts["ghcr.io"] == %{hits: 2, misses: 1, bytes_served: 100, mismatches: 1}
    assert snap.evictions == 3
    assert snap.digest_mismatches == 1
  end

  test "top lists at most 10 repositories by bytes served" do
    for n <- 1..12 do
      Stats.served("quay.io", "r/#{n}", n * 10)
      Stats.hit("quay.io", "r/#{n}")
    end

    top = Stats.snapshot().top
    assert length(top) == 10
    assert hd(top) == %{host: "quay.io", repo: "r/12", hits: 1, bytes_served: 120}
    assert Enum.map(top, & &1.bytes_served) == Enum.map(12..3//-1, &(&1 * 10))
  end
end
