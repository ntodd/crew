defmodule CrewProtocol.CommandTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.{Command, Examples}

  test "there's an example for every command type, and each one is valid" do
    assert Enum.sort(Map.keys(Examples.commands())) == Enum.sort(Command.types())

    for {type, payload} <- Examples.commands() do
      assert {:ok, %Command{type: ^type}} = Command.new(type, payload), type
    end
  end

  test "the vocabulary is fixed" do
    assert Enum.sort(Command.types()) ==
             Enum.sort(~w(vm.start vm.stop vm.log.ack vm.log.resend image.prepare image.remove
                          cache.config cache.purge box.inventory box.restart cachevm.restart
                          agent.update op.cancel))

    assert {:error, {:unknown_type, "exec"}} = Command.new("exec", %{})
  end

  test "commands round-trip through the wire format" do
    for {type, payload} <- Examples.commands() do
      {:ok, cmd} = Command.new(type, payload)
      wire = cmd |> Command.to_wire() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^cmd} = Command.from_wire(wire), type
    end
  end

  test "unknown fields are refused" do
    payload = Map.put(Examples.command("vm.stop"), "shell", "rm -rf /")
    assert {:error, [{"shell", "is not allowed"}]} = Command.new("vm.stop", payload)
  end

  test "a malformed op_id is refused" do
    wire = %{"op_id" => "../x", "type" => "box.inventory", "payload" => %{}}
    assert {:error, _} = Command.from_wire(wire)
    assert {:error, :malformed} = Command.from_wire(%{"type" => "box.inventory"})
  end

  describe "vm.start" do
    setup do: %{start: Examples.command("vm.start")}

    # Conformance mode (§11.6) is the agent's own setting: the control
    # plane has no way to ask for it.
    test "can't carry a conformance object or flag", %{start: start} do
      for value <- [%{"checks" => ["sizing"]}, true, "1"] do
        assert {:error, [{"conformance", "is not allowed"}]} =
                 Command.new("vm.start", Map.put(start, "conformance", value))
      end
    end

    test "a jit_config over 16 KiB is refused", %{start: start} do
      big = Base.encode64(:binary.copy("a", 16 * 1024))

      assert {:error, [{"jit_config", _}]} =
               Command.new("vm.start", %{start | "jit_config" => big})
    end

    test "the runner name must be a Crew runner name", %{start: start} do
      assert {:error, [{"name", _}]} =
               Command.new("vm.start", %{start | "name" => "ubuntu-latest"})
    end

    test "sizes follow the size rules", %{start: start} do
      size = %{start["size"] | "vcpus" => 3}
      assert {:error, [{"size.vcpus", _}]} = Command.new("vm.start", %{start | "size" => size})
    end

    test "the arch is x64 or arm64", %{start: start} do
      image = %{start["image"] | "arch" => "riscv"}
      assert {:error, [{"image.arch", _}]} = Command.new("vm.start", %{start | "image" => image})
    end

    test "labels are a non-empty list of short labels", %{start: start} do
      assert {:error, _} = Command.new("vm.start", %{start | "labels" => []})

      assert {:error, _} =
               Command.new("vm.start", %{start | "labels" => [String.duplicate("a", 300)]})
    end

    test "the jit_config is never shown by inspect", %{start: start} do
      {:ok, cmd} = Command.new("vm.start", start)
      refute inspect(cmd) =~ start["jit_config"]
      assert inspect(cmd) =~ ":redacted"
    end

    test "redact/1 drops the jit_config from a wire map, wherever it is", %{start: start} do
      {:ok, cmd} = Command.new("vm.start", start)
      wire = Command.to_wire(cmd)
      redacted = Command.redact(wire)
      refute Map.has_key?(redacted["payload"], "jit_config")
      assert redacted["payload"]["vm_id"] == start["vm_id"]
      assert Command.redact(%{"jit_config" => "x", "a" => 1}) == %{"a" => 1}
    end
  end

  describe "vm.stop" do
    test "grace_s is 0 to 300" do
      stop = Examples.command("vm.stop")
      assert {:ok, _} = Command.new("vm.stop", %{stop | "grace_s" => 300})
      assert {:error, [{"grace_s", _}]} = Command.new("vm.stop", %{stop | "grace_s" => 301})
    end

    test "the reason comes from a fixed list" do
      stop = Examples.command("vm.stop")
      assert {:error, [{"reason", _}]} = Command.new("vm.stop", %{stop | "reason" => "because"})
    end
  end

  describe "cache commands" do
    test "cache.config only enables hosts Crew knows" do
      config = Examples.command("cache.config")

      assert {:error, [{"enabled_hosts", _}]} =
               Command.new("cache.config", %{config | "enabled_hosts" => ["evil.example"]})
    end

    test "cache.config can have no parent" do
      config = Examples.command("cache.config") |> Map.put("parent", nil)
      assert {:ok, %{payload: payload}} = Command.new("cache.config", config)
      refute Map.has_key?(payload, :parent)
    end

    test "the parent's token is redacted" do
      config = Examples.command("cache.config")
      {:ok, cmd} = Command.new("cache.config", config)
      refute inspect(cmd) =~ config["parent"]["token"]

      refute cmd |> Command.to_wire() |> Command.redact() |> inspect() =~
               config["parent"]["token"]
    end

    test "cache.purge takes all, host:<host> or repo:<host>/<path>" do
      for scope <- ["all", "host:ghcr.io", "repo:ghcr.io/actions/runner"] do
        assert {:ok, _} = Command.new("cache.purge", %{"scope" => scope}), scope
      end

      for scope <- [
            "everything",
            "host:",
            "host:evil.example",
            "repo:ghcr.io",
            "repo:ghcr.io/../x"
          ] do
        assert {:error, _} = Command.new("cache.purge", %{"scope" => scope}), scope
      end
    end
  end

  describe "agent.update" do
    test "carries the agent tarball's size, and crew_cache's tarball for a Linux box" do
      assert {:ok, %{payload: p}} = Command.new("agent.update", Examples.command("agent.update"))
      assert p.size > 0
      assert p.cache.size > 0
      assert p.cache.url =~ "crew-cache-"

      macos = Map.delete(Examples.command("agent.update"), "cache")
      assert {:ok, %{payload: p}} = Command.new("agent.update", macos)
      refute Map.has_key?(p, :cache)
    end

    test "every tarball needs its URL, SHA-256, size and signature" do
      update = Examples.command("agent.update")

      for key <- ~w(url sha256 size signature) do
        assert {:error, _} = Command.new("agent.update", Map.delete(update, key)), key

        assert {:error, _} =
                 Command.new("agent.update", update_in(update, ["cache"], &Map.delete(&1, key))),
               "cache.#{key}"
      end

      assert {:error, _} = Command.new("agent.update", %{update | "version" => "../1.0.0"})
      assert {:error, _} = Command.new("agent.update", %{update | "sha256" => "abc"})
    end
  end
end
