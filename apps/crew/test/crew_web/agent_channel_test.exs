defmodule CrewWeb.AgentChannelTest do
  use CrewWeb.ChannelCase

  alias Crew.{Agents, Boxes, Operations, Repo, Scope}
  alias CrewProtocol.{Auth, Command, Event, Examples}
  alias CrewWeb.AgentSocket

  setup do
    %{box: box_fixture()}
  end

  describe "connect" do
    test "accepts a correctly signed connect", %{box: box} do
      assert {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      assert socket.assigns.box_id == box.id
      assert AgentSocket.id(socket) == "agent_socket:#{box.id}"
    end

    test "refuses a replayed connect", %{box: box} do
      info = signed_connect_info(box)
      assert {:ok, _} = connect(AgentSocket, %{}, connect_info: info)
      assert :error = connect(AgentSocket, %{}, connect_info: info)
    end

    test "refuses stale clocks, other keys, unknown and revoked agents", %{box: box} do
      assert :error =
               connect(AgentSocket, %{},
                 connect_info: signed_connect_info(box, now: System.os_time(:second) - 120)
               )

      other_key = elem(Auth.generate_keypair(), 1)

      assert :error =
               connect(AgentSocket, %{}, connect_info: signed_connect_info(box, key: other_key))

      stranger = %{box | id: CrewProtocol.uuid7()}

      assert :error =
               connect(AgentSocket, %{},
                 connect_info: signed_connect_info(stranger, key: private_key(box.id))
               )

      {:ok, _} = Boxes.revoke(Scope.for_user(user_fixture(role: "admin")), Repo.reload!(box))
      assert :error = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
    end
  end

  describe "join" do
    test "only the agent's own topic, and the box goes online", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      other = box_fixture()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "agent:#{other.id}", join_payload(other))

      assert {:ok, _, _} = subscribe_and_join(socket, "agent:#{box.id}", join_payload(box))
      assert Agents.online?(box.id)
      assert Repo.reload!(box).online_at
    end

    test "an unsupported protocol or a bad payload is refused", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:error, %{reason: "unsupported protocol version"}} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(box, %{"protocol_version" => 99})
               )

      assert {:error, %{reason: "invalid join payload"}} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(box, %{"box_name" => "Bad Name"})
               )
    end

    test "leaving marks the box offline", %{box: box} do
      socket = join_as(box)
      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)
      close(socket)
      assert_receive {:DOWN, ^ref, _, _, _}
      # The registry drops a dead process's keys asynchronously.
      assert eventually(fn -> not Agents.online?(box.id) end)
      assert Repo.reload!(box).offline_at
    end
  end

  describe "events" do
    test "capabilities are recorded", %{box: box} do
      socket = join_as(box)
      ref = push(socket, "event", event_wire("box.capabilities"))
      assert_reply ref, :ok
      assert Repo.reload!(box).capabilities["vcpus"] == 18
    end

    test "metrics are stored, in Unix seconds", %{box: box} do
      socket = join_as(box)
      ref = push(socket, "event", event_wire("box.metrics"))
      assert_reply ref, :ok
      assert %{cpu_pct: 30.0, t: 1_800_000_000} = Crew.Metrics.latest_box(box.id)
    end

    test "invalid events are refused", %{box: box} do
      socket = join_as(box)
      ref = push(socket, "event", %{"type" => "box.metrics", "payload" => %{"t" => "soon"}})
      assert_reply ref, :error, %{reason: "invalid event"}
    end

    test "the null driver is refused unless CREW_DEV", %{box: box} do
      socket = join_as(box)
      caps = Map.put(Examples.event("box.capabilities"), "driver", "null")
      ref = push(socket, "event", %{"type" => "box.capabilities", "payload" => caps})
      assert_reply ref, :error, %{reason: "the null driver is for development only"}

      Application.put_env(:crew, :dev, true)
      on_exit(fn -> Application.delete_env(:crew, :dev) end)
      ref = push(socket, "event", %{"type" => "box.capabilities", "payload" => caps})
      assert_reply ref, :ok
    end
  end

  describe "operations" do
    test "a command reaches the agent, and its result is recorded", %{box: box} do
      socket = join_as(box)
      assert {:ok, op} = Operations.dispatch(box.id, "box.inventory", %{})
      assert_push "command", %{"type" => "box.inventory", "op_id" => op_id}
      assert op_id == op.id

      ref =
        push(socket, "event", %{
          "type" => "op.result",
          "payload" => %{"op_id" => op.id, "status" => "ok", "result" => %{}}
        })

      assert_reply ref, :ok
      assert Operations.get!(op.id).status == "succeeded"
    end

    test "an agent can't report on another box's operation", %{box: box} do
      other = box_fixture()
      _other_socket = join_as(other)
      {:ok, op} = Operations.dispatch(other.id, "box.inventory", %{})

      socket = join_as(box)

      ref =
        push(socket, "event", %{
          "type" => "op.result",
          "payload" => %{"op_id" => op.id, "status" => "ok"}
        })

      assert_reply ref, :error, %{reason: "not this box's operation"}
      assert Operations.get!(op.id).status == "dispatched"
    end

    test "the JIT config never reaches the operation row", %{box: box} do
      _socket = join_as(box)
      start = Examples.command("vm.start")
      {:ok, op} = Operations.dispatch(box.id, "vm.start", start)
      assert_push "command", %{"payload" => %{"jit_config" => jit}}
      assert jit == start["jit_config"]
      refute Map.has_key?(Operations.get!(op.id).args, "jit_config")
    end

    test "a command for an offline box isn't sent", %{box: box} do
      assert {:error, :offline} = Operations.dispatch(box.id, "box.inventory", %{})
    end

    test "an invalid command is refused before it leaves", %{box: box} do
      _socket = join_as(box)
      assert {:error, _} = Operations.dispatch(box.id, "vm.stop", %{"vm_id" => "nope"})
    end
  end

  defp event_wire(type), do: %{"type" => type, "payload" => Examples.event(type)}

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "a second connection for the same box replaces the first", %{box: box} do
    first = join_as(box)
    Process.unlink(first.channel_pid)
    ref = Process.monitor(first.channel_pid)
    _second = join_as(box)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Agents.online?(box.id)
    _ = {Command, Event}
  end
end
