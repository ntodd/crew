defmodule CrewCache.UpstreamTest do
  use ExUnit.Case, async: true

  alias CrewCache.Upstream

  # Finch raises when it can't check out a connection in time (or has no
  # pool at all); a fetch has to see an error it can fall back from.
  test "send_one/4 turns a raise from Finch into an error, with the sink unstarted" do
    sink = {fn _, acc -> {:cont, acc} end, %{started: false}}

    assert {:error, %{__exception__: true}, %{started: false}} =
             Upstream.send_one("GET", "https://registry.test/v2/", [],
               finch: CrewCache.NoSuchFinch,
               sink: sink
             )
  end

  test "normalise_accept/1 keys on the types alone, sorted" do
    assert Upstream.normalise_accept("b/x;q=0.5, a/y ,B/X") == "a/y,b/x"
    assert Upstream.normalise_accept(nil) == ""
  end
end
