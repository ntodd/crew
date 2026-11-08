defmodule CrewAgent.GuestSampleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrewAgent.GuestSample

  defp sample(t, rx, tx), do: %{t: t, net_rx_bytes: rx, net_tx_bytes: tx}

  describe "rates/2" do
    test "network bytes between two samples become bits a second" do
      assert %{net_rx_bps: 8000.0, net_tx_bps: 1600.0} =
               GuestSample.rates(sample(10_000, 1_000, 500), sample(15_000, 6_000, 1_500))
    end

    test "the first sample has nothing to compare with, so its rates are 0" do
      assert %{net_rx_bps: +0.0, net_tx_bps: +0.0} =
               GuestSample.rates(nil, sample(15_000, 6_000, 1_500))
    end

    test "a counter that went backwards gives 0 for that direction" do
      assert %{net_rx_bps: +0.0, net_tx_bps: 1600.0} =
               GuestSample.rates(sample(10_000, 9_000, 500), sample(15_000, 10, 1_500))
    end

    test "samples with no time between them give 0" do
      assert %{net_rx_bps: +0.0, net_tx_bps: +0.0} =
               GuestSample.rates(sample(15_000, 0, 0), sample(15_000, 6_000, 1_500))

      assert %{net_rx_bps: +0.0} =
               GuestSample.rates(sample(16_000, 0, 0), sample(15_000, 6_000, 1_500))
    end

    test "an older guest's sample without counters gives 0" do
      assert %{net_rx_bps: +0.0, net_tx_bps: +0.0} =
               GuestSample.rates(%{t: 10_000}, %{t: 15_000})
    end

    property "rates are the bits sent over the time between, or 0, never negative" do
      check all(
              t0 <- integer(0..1_000_000),
              dt <- integer(-10_000..60_000),
              rx0 <- integer(0..1_000_000_000_000),
              rx1 <- integer(0..1_000_000_000_000),
              tx0 <- integer(0..1_000_000_000_000),
              tx1 <- integer(0..1_000_000_000_000)
            ) do
        %{net_rx_bps: rx, net_tx_bps: tx} =
          GuestSample.rates(sample(t0, rx0, tx0), sample(t0 + dt, rx1, tx1))

        for {bps, b0, b1} <- [{rx, rx0, rx1}, {tx, tx0, tx1}] do
          assert is_float(bps) and bps >= 0

          if dt > 0 and b1 >= b0,
            do: assert_in_delta(bps, (b1 - b0) * 8 * 1000 / dt, 1.0e-9 * bps + 1.0e-9),
            else: assert(bps == 0)
        end
      end
    end
  end

  describe "pressure" do
    defp stalls(t, cpu, mem, full),
      do: %{t: t, cpu_some_us: cpu, mem_some_us: mem, mem_full_us: full}

    test "stall totals become the share of the interval spent stalled" do
      assert %{cpu_pressure_pct: 20.0, mem_pressure_pct: 2.0, mem_full_pressure_pct: 0.5} =
               GuestSample.rates(
                 stalls(10_000, 1_000_000, 0, 0),
                 stalls(15_000, 2_000_000, 100_000, 25_000)
               )
    end

    # PSI's clock and the guest's wall clock can disagree a little.
    test "a share is at most 100%" do
      assert %{cpu_pressure_pct: 100.0} =
               GuestSample.rates(stalls(10_000, 0, 0, 0), stalls(15_000, 6_000_000, 0, 0))
    end

    test "is unknown (nil) without both totals, or when one went backwards" do
      assert %{cpu_pressure_pct: nil, mem_pressure_pct: nil, mem_full_pressure_pct: nil} =
               GuestSample.rates(nil, stalls(15_000, 1, 1, 1))

      assert %{cpu_pressure_pct: nil} =
               GuestSample.rates(%{t: 10_000}, stalls(15_000, 1, 1, 1))

      assert %{cpu_pressure_pct: nil, mem_pressure_pct: 0.0} =
               GuestSample.rates(stalls(10_000, 5, 0, 0), stalls(15_000, 1, 0, 0))

      assert %{cpu_pressure_pct: nil} =
               GuestSample.rates(stalls(15_000, 0, 0, 0), stalls(15_000, 1, 0, 0))
    end

    property "is nil or a share from 0 to 100" do
      check all(
              t0 <- integer(0..1_000_000),
              dt <- integer(-10_000..60_000),
              a <- one_of([constant(nil), integer(0..10_000_000_000)]),
              b <- one_of([constant(nil), integer(0..10_000_000_000)])
            ) do
        %{cpu_pressure_pct: pct} =
          GuestSample.rates(%{t: t0, cpu_some_us: a}, %{t: t0 + dt, cpu_some_us: b})

        assert pct == nil or (is_float(pct) and pct >= 0 and pct <= 100)
        if a == nil or b == nil or dt <= 0 or b < a, do: assert(pct == nil)
      end
    end
  end

  test "max_known/2 takes the larger reading, ignoring an unknown one" do
    assert GuestSample.max_known(nil, nil) == nil
    assert GuestSample.max_known(nil, 5) == 5
    assert GuestSample.max_known(7, nil) == 7
    assert GuestSample.max_known(7, 9) == 9
  end
end
