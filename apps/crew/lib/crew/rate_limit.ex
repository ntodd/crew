defmodule Crew.RateLimit do
  @moduledoc """
  In-memory rate limits for sign-in, enrollment and agent connects.

  Agent connects count failed verifications to bound refusal logging.
  Enrollment checks its failure budget before accepting a request.
  Keys use the real client address (`CrewWeb.ClientIP`).

  Each key's window starts at its first hit, not on a wall-clock
  boundary, so a burst is counted whole wherever it falls on the clock.
  A key always takes the same `scale`.
  """
  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  @doc "Whether `key` has used up `limit` within `scale` ms, without counting anything."
  @spec exhausted?(String.t(), pos_integer(), pos_integer()) :: boolean()
  def exhausted?(key, scale, limit), do: get(key, scale) >= limit

  @doc """
  Counts a failure against `key`. Returns `:first_over` the first time
  the count passes `limit` in the window, so callers can log once.
  """
  @spec failed(String.t(), pos_integer(), pos_integer()) :: :ok | :first_over
  def failed(key, scale, limit), do: if(inc(key, scale) == limit + 1, do: :first_over, else: :ok)
end
