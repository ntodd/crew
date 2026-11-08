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
end
