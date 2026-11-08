defmodule CrewAgent.GuestSample do
  @moduledoc """
  What the agent works out from two consecutive guest samples (§13.5
  step 10): the guest sends running totals, and `vm.metrics` carries
  rates over the interval between them.

  A first sample, a counter that went backwards (a reset) or samples with
  no time between them give a network rate of 0 and an unknown pressure,
  never a negative or made-up value.
  """

  @doc """
  Rates between `prev` and `cur` (`t` in Unix milliseconds): network bits
  a second, and the share of the interval some task (or, for full, every
  task) stalled on CPU or memory, from PSI's totals (§16.5). Pressure is
  nil when either sample lacks the total, as an older guest's do.
  """
  @spec rates(map() | nil, map()) :: map()
  def rates(prev, cur) do
    seconds = elapsed(prev, cur)

    %{
      net_rx_bps: per_second(prev, cur, :net_rx_bytes, seconds) * 8,
      net_tx_bps: per_second(prev, cur, :net_tx_bytes, seconds) * 8,
      cpu_pressure_pct: stalled(prev, cur, :cpu_some_us, seconds),
      mem_pressure_pct: stalled(prev, cur, :mem_some_us, seconds),
      mem_full_pressure_pct: stalled(prev, cur, :mem_full_us, seconds)
    }
  end

  @doc "The larger of two readings, either of which may be unknown (nil)."
  def max_known(nil, b), do: b
  def max_known(a, nil), do: a
  def max_known(a, b), do: max(a, b)

  defp elapsed(%{t: t0}, %{t: t1}) when is_integer(t0) and is_integer(t1) and t1 > t0,
    do: (t1 - t0) / 1000

  defp elapsed(_prev, _cur), do: nil

  defp stalled(_prev, _cur, _key, nil), do: nil

  defp stalled(prev, cur, key, seconds) do
    with a when is_integer(a) <- Map.get(prev, key),
         b when is_integer(b) and b >= a <- Map.get(cur, key) do
      Float.round(min((b - a) / (seconds * 1_000_000) * 100, 100.0), 2)
    else
      _ -> nil
    end
  end

  defp per_second(_prev, _cur, _key, nil), do: 0.0

  defp per_second(prev, cur, key, seconds) do
    with a when is_integer(a) <- Map.get(prev, key),
         b when is_integer(b) and b >= a <- Map.get(cur, key) do
      (b - a) / seconds
    else
      _ -> 0.0
    end
  end
end
