defmodule CrewProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CrewProtocol.{Command, Event, Examples, Text}

  test "the control plane accepts the current protocol and the one before" do
    v = CrewProtocol.version()
    assert CrewProtocol.compatible?(v)
    assert CrewProtocol.compatible?(v - 1) or v == 1
    refute CrewProtocol.compatible?(v + 1)
    refute CrewProtocol.compatible?("1")
  end

  describe "join" do
    test "a valid join" do
      assert {:ok, join} = CrewProtocol.cast_join(Examples.join())
      assert join.box_name == "m1ultra"
      assert join.in_flight == []
    end

    test "a join must name a valid box" do
      assert {:error, _} = CrewProtocol.cast_join(%{Examples.join() | "box_name" => "Bad Name"})
    end
  end

  describe "uuids" do
    test "v4 and v7 look like UUIDs" do
      for id <- [CrewProtocol.uuid(), CrewProtocol.uuid7()] do
        assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      end
    end

    test "v7 sorts by time" do
      a = CrewProtocol.uuid7(1_000)
      b = CrewProtocol.uuid7(2_000)
      assert a < b
      assert String.at(a, 14) == "7"
    end
  end

  describe "Text.cut/2" do
    test "cuts at a UTF-8 boundary" do
      assert Text.cut("héllo", 2) == {"h", true}
      assert Text.cut("héllo", 3) == {"hé", true}
      assert Text.cut("héllo", 100) == {"héllo", false}
      assert Text.cut("", 0) == {"", false}
    end

    test "scrub/1 replaces invalid bytes and NULs" do
      assert Text.scrub(<<"a", 0xFF, 0, "b">>) == "a��b"
    end
  end

  # Whatever arrives on the wire, validation answers; it never raises.
  property "commands and events never raise on junk" do
    check all(
            type <- member_of(Command.types() ++ Event.types() ++ ["nope"]),
            payload <- junk(),
            max_runs: 500
          ) do
      for fun <- [&Command.new/2, &Event.new/2] do
        case fun.(type, payload) do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end
      end
    end
  end

  property "mutating one field of a valid example never raises" do
    examples =
      (Map.to_list(Examples.commands()) ++ Map.to_list(Examples.events()))
      |> Enum.reject(fn {_, p} -> p == %{} end)

    check all(
            {type, payload} <- member_of(examples),
            value <- junk(),
            max_runs: 500
          ) do
      key = payload |> Map.keys() |> Enum.random()
      mutated = Map.put(payload, key, value)

      for fun <- [&Command.new/2, &Event.new/2] do
        assert match?({:ok, _}, fun.(type, mutated)) or match?({:error, _}, fun.(type, mutated))
      end
    end
  end

  defp junk do
    leaf =
      one_of([
        integer(),
        float(),
        boolean(),
        constant(nil),
        string(:printable, max_length: 40),
        binary(max_length: 40),
        constant(String.duplicate("a", 70_000))
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 5),
        map_of(string(:alphanumeric, max_length: 10), child, max_length: 5)
      ])
    end)
  end
end
