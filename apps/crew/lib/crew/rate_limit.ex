defmodule Crew.RateLimit do
  @moduledoc """
  In-memory rate limits for sign-in, enrollment and agent connects.

  Agent connects and enrollment count failures only (`exhausted?/3`
  before the attempt, `failed/3` after a failed one), so a client sending
  junk uses up its own allowance and never a correctly signed agent's.
  Keys use the real client address (`CrewWeb.ClientIP`).
  """
  use Hammer, backend: :ets

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
