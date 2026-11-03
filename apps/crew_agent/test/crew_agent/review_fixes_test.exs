defmodule CrewAgent.ReviewFixesTest do
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Config, Handler, Identity, VM, VMs}

  setup do
    attach()
    :ok
  end

  test "enrollment refuses a ws:// control plane without CREW_DEV, before sending the token" do
    config = %Config{
      url: "ws://crew.example/agent/websocket",
      join_token: "cj_secret",
      dev: false
    }

    test = self()
    plug = fn conn -> send(test, :requested) && Plug.Conn.send_resp(conn, 201, "{}") end
    assert {:error, message} = Identity.enroll(config, req_options: [plug: plug])
    assert message =~ "wss://"
    refute_received :requested
  end

  test "retained log batches count every line, not just its text" do
    vm_id = start()
    token = token_of(vm_id)
    body = String.duplicate(~s({"text":""}\n), 20_000)
    Req.post!(api() <> "/v1/log", body: body, auth: {:bearer, token}, retry: false)
    state = :sys.get_state(VM.whereis(vm_id))
    assert state.unacked_bytes + state.pending_bytes >= 20_000 * 32
    VMs.stop(vm_id, true, 0)
  end

  test "an adopted VM that ended while the agent was down keeps what it had reached" do
    vm_id = start([{"FAKE_JOB_SECONDS", "0"}])
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "job_finished"))
    pid = VM.whereis(vm_id)
    # Kill the server before it sees the exit (as an agent restart would).
    Process.exit(pid, :kill)
    Process.sleep(1500)
    :ok = VMs.adopt_all()
    exited = await("vm.exited", &(&1.vm_id == vm_id))
    assert exited.payload.reason == "poweroff"
  end

  test "a VM's unacknowledged logs outlive it, until acked" do
    vm_id = start([{"FAKE_JOB_SECONDS", "0"}])
    log = await("vm.log", &(&1.vm_id == vm_id))
    await("vm.exited", &(&1.vm_id == vm_id))

    %{epoch: epoch, seq: seq} = log.payload

    :ok =
      Handler.handle(
        cmd("vm.log.resend", %{"vm_id" => vm_id, "epoch" => epoch, "from_seq" => seq})
      )

    assert %{payload: %{seq: ^seq}} = await("vm.log", &(&1.vm_id == vm_id))

    :ok =
      Handler.handle(cmd("vm.log.ack", %{"vm_id" => vm_id, "epoch" => epoch, "seq" => seq + 100}))

    Process.sleep(100)
    refute VM.whereis(vm_id)
  end

  test "a resend for a VM the agent doesn't hold any more is answered gone" do
    vm_id = CrewProtocol.uuid7()

    :ok =
      Handler.handle(
        cmd("vm.log.resend", %{"vm_id" => vm_id, "epoch" => "0123456789abcdef", "from_seq" => 3})
      )

    await("vm.log.gone", &(&1.vm_id == vm_id))
  end

  test "the inventory stays within the protocol's bounds, live VMs first" do
    dir = Config.vms_dir(Config.get())

    for _ <- 1..1005 do
      id = CrewProtocol.uuid7()
      File.mkdir_p!(Path.join(dir, id))

      File.write!(
        Path.join([dir, id, "exited.json"]),
        Jason.encode!(%{
          "reason" => "poweroff",
          "code" => 0,
          "at" => System.os_time(:millisecond)
        })
      )
    end

    vms = VMs.inventory()
    assert length(vms) <= 1000
    assert {:ok, _} = CrewProtocol.Event.new("box.inventory", %{vms: vms, images: []})
    :ok = VMs.sweep_exited(-1)
    assert Enum.all?(VMs.inventory(), & &1.alive)
  end

  test "on vz, each VM gets its own guest.sock, and it only answers for that VM" do
    {:ok, pid} =
      CrewAgent.GuestAPI.start_socket(
        "vm-a",
        path =
          Path.join(System.tmp_dir!(), "crew-test-#{System.unique_integer([:positive])}.sock")
      )

    :ets.insert(VM.sessions_table(), {:crypto.hash(:sha256, "tok-b"), "vm-b", nil})

    resp =
      Req.get!("http://localhost/v1/payload",
        unix_socket: path,
        auth: {:bearer, "tok-b"},
        retry: false
      )

    assert resp.status == 401
    GenServer.stop(pid)
    refute File.exists?(path)
  end

  defp start(env \\ [{"FAKE_JOB_SECONDS", "30"}, {"FAKE_IDLE_SECONDS", "30"}]) do
    Application.put_env(:crew_agent, :null_env, env)
    cmd = start_command()
    :ok = Handler.handle(cmd)
    vm_id = cmd.payload.vm_id
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "booted"))
    vm_id
  end

  defp cmd(type, payload) do
    {:ok, c} = CrewProtocol.Command.new(type, payload)
    c
  end

  defp api, do: "http://127.0.0.1:#{CrewAgent.GuestAPI.port()}"

  defp token_of(vm_id),
    do: File.read!(Path.join(Config.vm_dir(Config.get(), vm_id), "null-token"))
end
