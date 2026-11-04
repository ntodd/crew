defmodule Crew.CacheTest do
  use ExUnit.Case, async: true

  alias Crew.Cache

  test "a value is computed once while fresh, then again" do
    key = {:test, make_ref()}
    parent = self()
    f = fn -> send(parent, :computed) && System.unique_integer() end

    a = Cache.fetch(key, 60_000, f)
    assert Cache.fetch(key, 60_000, f) == a
    assert_received :computed
    refute_received :computed

    b = Cache.fetch(key, 0, f)
    assert b != a
    assert_received :computed
  end
end
