defmodule CrewAgent.GuestSample do
  @moduledoc """
  What the agent works out from two consecutive guest samples (§13.5
  step 10): the guest sends running totals, and `vm.metrics` carries
  rates over the interval between them.

  A first sample, a counter that went backwards (a reset) or samples with
  no time between them give 0, never a negative or made-up rate.
  """

  @doc "Network rates in bits a second between `prev` and `cur` (`t` in Unix milliseconds)."
  @spec rates(map() | nil, map()) :: %{net_rx_bps: float(), net_tx_bps: float()}
  def rates(prev, cur) do
    seconds = elapsed(prev, cur)

    %{
      net_rx_bps: per_second(prev, cur, :net_rx_bytes, seconds) * 8,
      net_tx_bps: per_second(prev, cur, :net_tx_bytes, seconds) * 8
    }
  end

  defp elapsed(%{t: t0}, %{t: t1}) when is_integer(t0) and is_integer(t1) and t1 > t0,
    do: (t1 - t0) / 1000

  defp elapsed(_prev, _cur), do: nil

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
