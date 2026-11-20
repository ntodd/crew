defmodule Crew.RateLimitTest do
  use ExUnit.Case, async: true

  alias Crew.RateLimit

  @scale 1_000

  defp key, do: "rate-limit-test:#{System.unique_integer([:positive])}"

  # Waits until the wall clock is `ms` short of a multiple of `scale`.
  defp just_before_a_boundary(scale, ms) do
    left = scale - rem(System.system_time(:millisecond), scale)
    if left > ms, do: Process.sleep(left - ms), else: Process.sleep(left + scale - ms)
  end

  test "failures that cross a wall-clock boundary still count together" do
    key = key()
    just_before_a_boundary(@scale, 30)

    for _ <- 1..3 do
      RateLimit.failed(key, @scale, 3)
      Process.sleep(20)
    end

    assert RateLimit.exhausted?(key, @scale, 3)
  end

  test "failures stop counting once the window from the first one has passed" do
    key = key()
    RateLimit.failed(key, @scale, 1)
    assert RateLimit.exhausted?(key, @scale, 1)

    Process.sleep(@scale + 100)
    refute RateLimit.exhausted?(key, @scale, 1)
  end

  test "hit allows `limit` per window, measured from the first hit" do
    key = key()
    just_before_a_boundary(@scale, 30)

    assert {:allow, 1} = RateLimit.hit(key, @scale, 1)
    Process.sleep(60)
    assert {:deny, _} = RateLimit.hit(key, @scale, 1)
  end
end
