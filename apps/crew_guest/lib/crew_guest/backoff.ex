defmodule CrewGuest.Backoff do
  @moduledoc """
  Jittered exponential backoff: attempt `n` waits between half and all of
  `min * 2^(n-1)`, capped at `max`, and never less than `min`. With the
  defaults that's 0.5 s to 5 s (§13.5).
  """

  @spec delay(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def delay(attempt, min \\ 500, max \\ 5_000) do
    ceiling = min(max, min * Integer.pow(2, min(attempt - 1, 16)))
    half = max(div(ceiling, 2), 1)
    max(min, half + :rand.uniform(half))
  end
end
