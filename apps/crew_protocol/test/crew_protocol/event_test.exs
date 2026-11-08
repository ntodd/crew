defmodule CrewProtocol.EventTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.{Event, Examples}

  test "there's an example for every event type, and each one is valid" do
    assert Enum.sort(Map.keys(Examples.events())) == Enum.sort(Event.types())

    for {type, payload} <- Examples.events() do
      assert {:ok, %Event{type: ^type}} = Event.new(type, payload), type
    end
  end

  test "the vocabulary is the spec's" do
    assert Enum.sort(Event.types()) ==
             Enum.sort(~w(op.result vm.state vm.exited vm.log vm.log.gone vm.steps vm.metrics
                          box.metrics box.capabilities box.inventory box.reboot image.state
                          cache.stats))
  end

  test "events round-trip through the wire format" do
    for {type, payload} <- Examples.events() do
      {:ok, event} = Event.new(type, payload)
      wire = event |> Event.to_wire() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^event} = Event.from_wire(wire), type
    end
  end

  test "out-of-range values are refused, not clamped" do
    state = Examples.event("vm.state")

    assert {:error, [{"detail", _}]} =
             Event.new("vm.state", %{state | "detail" => String.duplicate("a", 1025)})

    steps = Examples.event("vm.steps")
    too_many = List.duplicate(hd(steps["steps"]), 1001)
    assert {:error, [{"steps", _}]} = Event.new("vm.steps", %{steps | "steps" => too_many})

    reboot = Examples.event("box.reboot")
    packages = Enum.map(1..51, &"pkg-#{&1}")
    assert {:error, _} = Event.new("box.reboot", %{reboot | "packages" => packages})
  end

  describe "vm.log" do
    test "a line's text is at most 64 KiB" do
      log = Examples.event("vm.log")
      [line] = log["lines"]
      ok = %{line | "text" => String.duplicate("a", 65_536)}
      assert {:ok, _} = Event.new("vm.log", %{log | "lines" => [ok]})

      long = %{line | "text" => String.duplicate("a", 65_537)}
      assert {:error, _} = Event.new("vm.log", %{log | "lines" => [long]})
    end

    test "a message is at most 256 KiB of text" do
      log = Examples.event("vm.log")
      [line] = log["lines"]

      lines =
        for n <- 1..5, do: %{line | "n" => n, "text" => String.duplicate("a", 60_000)}

      assert {:error, [{"lines", "is over 256 KiB"}]} =
               Event.new("vm.log", %{log | "lines" => lines})
    end

    test "the cap is on the encoded message, not just the text" do
      log = Examples.event("vm.log")
      [line] = log["lines"]
      lines = for n <- 1..4, do: %{line | "n" => n, "text" => String.duplicate("a", 65_536)}

      assert {:error, [{"lines", "is over 256 KiB"}]} =
               Event.new("vm.log", %{log | "lines" => lines})

      # Escaping widens control characters six-fold on the wire.
      escaped =
        for n <- 1..2, do: %{line | "n" => n, "text" => String.duplicate("\u0001", 30_000)}

      assert {:error, [{"lines", "is over 256 KiB"}]} =
               Event.new("vm.log", %{log | "lines" => escaped})
    end

    test "step_ref is a short token" do
      log = Examples.event("vm.log")
      [line] = log["lines"]

      assert {:error, _} =
               Event.new("vm.log", %{log | "lines" => [%{line | "step_ref" => "../../x"}]})
    end

    test "the epoch is 16 hex characters" do
      log = Examples.event("vm.log")
      assert {:error, [{"epoch", _}]} = Event.new("vm.log", %{log | "epoch" => "123"})
    end
  end

  describe "vm.metrics' newer readings" do
    test "are optional, so an older agent's sample is still valid" do
      assert {:ok, %Event{payload: p}} = Event.new("vm.metrics", Examples.event("vm.metrics"))
      refute Map.has_key?(p, :mem_peak_mib)
      refute Map.has_key?(p, :cpu_pressure_pct)
    end

    test "carry the high-water mark, OOM kills and pressure" do
      payload =
        Map.merge(Examples.event("vm.metrics"), %{
          "mem_peak_mib" => 3000,
          "oom_kills" => 1,
          "cpu_pressure_pct" => 12.5,
          "mem_pressure_pct" => 3.0,
          "mem_full_pressure_pct" => 0.5
        })

      assert {:ok, %Event{payload: p}} = Event.new("vm.metrics", payload)

      assert %{
               mem_peak_mib: 3000,
               oom_kills: 1,
               cpu_pressure_pct: 12.5,
               mem_pressure_pct: 3.0,
               mem_full_pressure_pct: 0.5
             } = p
    end

    test "refuse a pressure outside 0 to 100, or a negative count" do
      base = Examples.event("vm.metrics")

      for {field, bad} <- [
            {"cpu_pressure_pct", 100.5},
            {"mem_pressure_pct", -1},
            {"mem_full_pressure_pct", 101},
            {"oom_kills", -1},
            {"mem_peak_mib", -1}
          ] do
        assert {:error, [{^field, msg}]} = Event.new("vm.metrics", Map.put(base, field, bad)),
               field

        refute msg == "is not allowed", field
      end
    end
  end

  test "string list items are held to the string maximum" do
    reboot = Examples.event("box.reboot")

    assert {:error, _} =
             Event.new("box.reboot", %{reboot | "packages" => [String.duplicate("p", 5000)]})
  end

  test "an error result must say what the error was" do
    result = %{"op_id" => Examples.vm_id(), "status" => "error"}
    assert {:error, [{"error", "is required"}]} = Event.new("op.result", result)

    assert {:ok, _} =
             Event.new(
               "op.result",
               Map.put(result, "error", %{"code" => "duplicate", "message" => "x"})
             )
  end

  test "vm.exited's reason comes from a fixed list" do
    exited = Examples.event("vm.exited")
    assert {:error, [{"reason", _}]} = Event.new("vm.exited", %{exited | "reason" => "bored"})
  end

  test "vm.exited's exit status can be negative (a signal)" do
    exited = Examples.event("vm.exited")
    assert {:ok, _} = Event.new("vm.exited", %{exited | "exit_status" => -9})
  end

  test "box.inventory's exited is an object or null" do
    inventory = Examples.event("box.inventory")
    [vm] = inventory["vms"]

    assert {:ok, _} =
             Event.new("box.inventory", %{inventory | "vms" => [%{vm | "exited" => nil}]})
  end

  test "box.capabilities' arch and driver come from fixed lists" do
    caps = Examples.event("box.capabilities")
    assert {:error, _} = Event.new("box.capabilities", %{caps | "guest_arch" => "mips"})
    assert {:error, _} = Event.new("box.capabilities", %{caps | "driver" => "docker"})
  end
end
