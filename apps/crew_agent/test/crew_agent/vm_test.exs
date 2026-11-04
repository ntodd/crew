defmodule CrewAgent.VMTest do
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Handler, VM, VMs}

  setup do
    attach()
    Application.put_env(:crew_agent, :null_env, [])
    on_exit(fn -> Application.delete_env(:crew_agent, :null_env) end)
    :ok
  end

  defp api, do: "http://127.0.0.1:#{CrewAgent.GuestAPI.port()}"

  # A guest we drive by hand: the VM's token, read the way the null
  # driver passes it to its process.
  defp start_vm(
         cmd \\ start_command(),
         env \\ [{"FAKE_JOB_SECONDS", "30"}, {"FAKE_IDLE_SECONDS", "30"}]
       ) do
    Application.put_env(:crew_agent, :null_env, env)
    assert :ok = Handler.handle(cmd)
    cmd.payload.vm_id
  end

  test "a VM goes through its life: booted, listening, running, logs, steps, finished, exited" do
    cmd = start_command()
    vm_id = start_vm(cmd, [{"FAKE_JOB_SECONDS", "0"}])

    events =
      collect_until(&(&1.type == "vm.exited" and &1.payload.vm_id == vm_id))
      |> Enum.filter(&(&1.payload[:vm_id] == vm_id))

    states = for %{type: "vm.state", payload: p} <- events, do: p.state
    assert states == ~w(booted runner_listening job_started job_finished)

    [log | _] = for %{type: "vm.log"} = e <- events, do: e
    assert [%{text: "hello from the null driver", n: 1} | _] = log.payload.lines
    assert log.payload.epoch =~ ~r/\A[0-9a-f]{16}\z/
    assert log.payload.seq == 1

    assert [%{payload: %{steps: [%{ref: "s1", name: "Run tests"}]}} | _] =
             for(%{type: "vm.steps"} = e <- events, do: e)

    exited = List.last(events)
    assert exited.payload.reason == "poweroff"
    assert exited.payload.cleanup == "ok"
    # Its server holds the unacknowledged logs, and nothing else.
    assert :sys.get_state(VM.whereis(vm_id)).exited

    assert [%{vm_id: ^vm_id, alive: false, exited: %{reason: "poweroff"}}] =
             Enum.filter(VMs.inventory(), &(&1.vm_id == vm_id))

    # box.metrics' vms_running counts VMs that run, not servers holding logs.
    assert VMs.running_count() == Enum.count(VMs.inventory(), & &1.alive)
  end

  test "vm.start is idempotent by vm_id" do
    cmd = start_command()
    vm_id = start_vm(cmd)
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "booted"))
    assert :ok = Handler.handle(cmd)
    VMs.stop(vm_id, true, 0)
    await("vm.exited", &(&1.vm_id == vm_id))
    assert {:error, "duplicate", _} = Handler.handle(cmd)
  end

  describe "the guest API" do
    setup do
      vm_id = start_vm()
      await("vm.state", &(&1.vm_id == vm_id and &1.state == "runner_listening"))
      on_exit(fn -> VMs.stop(vm_id, true, 0) end)
      %{vm_id: vm_id}
    end

    test "the payload is served once", %{vm_id: vm_id} do
      token = token_of(vm_id)

      assert %{status: 410} =
               Req.get!(api() <> "/v1/payload", auth: {:bearer, token}, retry: false)

      assert %{payload: %{state: "booted", detail: "payload_refetch"}} =
               await("vm.state", &(&1.detail == "payload_refetch"))
    end

    test "unknown tokens are refused", %{vm_id: _} do
      assert %{status: 401} =
               Req.get!(api() <> "/v1/payload", auth: {:bearer, "nope"}, retry: false)

      assert %{status: 401} = Req.get!(api() <> "/v1/payload", retry: false)
    end

    test "each state once, forward only", %{vm_id: vm_id} do
      token = token_of(vm_id)

      post = fn body ->
        Req.post!(api() <> "/v1/state", json: body, auth: {:bearer, token}, retry: false).status
      end

      assert post.(%{"state" => "runner_listening"}) == 422
      assert post.(%{"state" => "job_started"}) in [204, 422]
      assert post.(%{"state" => "booted"}) == 422
    end

    test "a graceful stop reaches the guest, and is forced after the grace", %{vm_id: vm_id} do
      token = token_of(vm_id)

      task =
        Task.async(fn ->
          Req.get!(api() <> "/v1/control",
            auth: {:bearer, token},
            retry: false,
            receive_timeout: 35_000
          )
        end)

      Process.sleep(100)
      assert :ok = VMs.stop(vm_id, false, 1)
      assert %{status: 200, body: %{"stop" => true}} = Task.await(task)

      # Every response now says stop.
      assert %{status: 200, body: %{"stop" => true}} =
               Req.post!(api() <> "/v1/metrics",
                 json: %{"cpu_pct" => 5},
                 auth: {:bearer, token},
                 retry: false
               )

      exited = await("vm.exited", &(&1.vm_id == vm_id))
      assert exited.payload.reason == "killed_stop"
    end

    test "rates are limited", %{vm_id: vm_id} do
      token = token_of(vm_id)

      statuses =
        for _ <- 1..4,
            do:
              Req.post!(api() <> "/v1/metrics", json: %{}, auth: {:bearer, token}, retry: false).status

      assert 429 in statuses
    end
  end

  test "logs are acked, resent, and reported gone" do
    vm_id = start_vm(start_command(), [{"FAKE_JOB_SECONDS", "30"}])
    log = await("vm.log", &(&1.vm_id == vm_id))
    %{epoch: epoch, seq: seq} = log.payload

    # Resent while unacked…
    assert :ok =
             Handler.handle(
               cmd("vm.log.resend", %{"vm_id" => vm_id, "epoch" => epoch, "from_seq" => seq})
             )

    assert %{payload: %{seq: ^seq}} = await("vm.log", &(&1.vm_id == vm_id))

    # …and gone once acked.
    assert :ok =
             Handler.handle(
               cmd("vm.log.ack", %{"vm_id" => vm_id, "epoch" => epoch, "seq" => seq})
             )

    assert :ok =
             Handler.handle(
               cmd("vm.log.resend", %{"vm_id" => vm_id, "epoch" => epoch, "from_seq" => seq})
             )

    assert %{payload: %{up_to_seq: ^seq}} = await("vm.log.gone", &(&1.vm_id == vm_id))

    # An old epoch is gone entirely.
    assert :ok =
             Handler.handle(
               cmd("vm.log.resend", %{
                 "vm_id" => vm_id,
                 "epoch" => "0000000000000000",
                 "from_seq" => 1
               })
             )

    await("vm.log.gone", &(&1.epoch == "0000000000000000"))
    VMs.stop(vm_id, true, 0)
  end

  # §11.6 item 9: the guest had a 204 for these lines, so it won't send
  # them again; the agent holds them (for its 250 ms batch, then until
  # they're acked) only in memory. A restart (an update, systemctl)
  # sends them and waits for the ack before the VMs' servers go.
  test "an agent stop sends the lines the guest has posted, and waits for their ack" do
    vm_id = start_vm(start_command(), [{"FAKE_JOB_SECONDS", "30"}])
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "job_started"))

    line =
      ~s({"t":#{System.os_time(:millisecond)},"step_ref":"s1","text":"just before the stop"}\n)

    assert %{status: 204} =
             Req.post!(api() <> "/v1/log",
               body: line,
               auth: {:bearer, token_of(vm_id)},
               headers: [{"content-type", "application/x-ndjson"}],
               retry: false
             )

    drain = Task.async(fn -> VMs.drain_logs(5_000, [vm_id]) end)

    log =
      await("vm.log", fn p ->
        p.vm_id == vm_id and Enum.any?(p.lines, &(&1.text == "just before the stop"))
      end)

    # Sent, but not acked yet: the stop still waits.
    refute Task.yield(drain, 300)

    # Lines from now on are the next agent's: 503, which crew-guest retries.
    assert %{status: 503} =
             Req.post!(api() <> "/v1/log",
               body: line,
               auth: {:bearer, token_of(vm_id)},
               headers: [{"content-type", "application/x-ndjson"}],
               retry: false
             )

    assert :ok = VMs.log_ack(vm_id, log.payload.epoch, log.payload.seq)
    assert Task.await(drain) == :ok
    VMs.stop(vm_id, true, 0)
  end

  test "the application drains the VMs' logs before it stops" do
    vm_id = start_vm(start_command(), [{"FAKE_JOB_SECONDS", "30"}])
    log = await("vm.log", &(&1.vm_id == vm_id))
    stopping = Task.async(fn -> CrewAgent.Application.prep_stop(:state) end)
    refute Task.yield(stopping, 300)
    _ = await_acking_logs(vm_id, log)
    assert Task.await(stopping) == :state
    VMs.stop(vm_id, true, 0)
  end

  # Acks every log batch of the VM until one has come for a while.
  defp await_acking_logs(vm_id, log) do
    VMs.log_ack(vm_id, log.payload.epoch, log.payload.seq)

    receive do
      {:outbox_deliver, %{type: "vm.log", payload: %{vm_id: ^vm_id}} = next, _ack} ->
        await_acking_logs(vm_id, next)
    after
      500 -> :ok
    end
  end

  test "an agent stop with no control plane attached doesn't wait for acks" do
    vm_id = start_vm(start_command(), [{"FAKE_JOB_SECONDS", "30"}])
    await("vm.log", &(&1.vm_id == vm_id))
    :ok = CrewAgent.Outbox.detach()
    {us, :ok} = :timer.tc(fn -> VMs.drain_logs(5_000, [vm_id]) end)
    assert us < 1_000_000
    attach()
    VMs.stop(vm_id, true, 0)
  end

  test "a VM past its deadline is killed" do
    vm_id =
      start_vm(start_command(%{"deadline" => System.os_time(:second) + 1}), [
        {"FAKE_JOB_SECONDS", "30"}
      ])

    exited = await("vm.exited", &(&1.vm_id == vm_id), 15_000)
    assert exited.payload.reason == "killed_deadline"
  end

  test "a guest that never comes up is boot_failed" do
    vm_id = start_vm(start_command(), [{"CREW_GUEST_API", "http://127.0.0.1:1"}])
    VMs.stop(vm_id, true, 0)
    exited = await("vm.exited", &(&1.vm_id == vm_id))
    assert exited.payload.reason in ["boot_failed", "killed_stop"]
  end

  test "adoption: a VM whose server died is taken back, with a new epoch, and keeps its session" do
    vm_id = start_vm()
    first = await("vm.state", &(&1.vm_id == vm_id and &1.state == "runner_listening"))
    assert first
    old = :sys.get_state(VM.whereis(vm_id)).epoch

    # The server goes (as on an agent restart); the "VM" keeps running.
    pid = VM.whereis(vm_id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    :ok = VMs.adopt_all()
    new_pid = VM.whereis(vm_id)
    assert new_pid
    refute :sys.get_state(new_pid).epoch == old

    token = token_of(vm_id)

    assert %{status: status} =
             Req.post!(api() <> "/v1/metrics",
               json: %{"cpu_pct" => 1},
               auth: {:bearer, token},
               retry: false
             )

    assert status in [204, 429]
    VMs.stop(vm_id, true, 0)
  end

  test "the JIT config isn't written anywhere on disk" do
    cmd = start_command()
    vm_id = start_vm(cmd)
    await("vm.state", &(&1.vm_id == vm_id and &1.state == "booted"))
    dir = CrewAgent.Config.vm_dir(CrewAgent.Config.get(), vm_id)

    for f <- File.ls!(dir), File.regular?(Path.join(dir, f)) do
      refute File.read!(Path.join(dir, f)) =~ cmd.payload.jit_config, "#{f} has the JIT config"
    end

    VMs.stop(vm_id, true, 0)
  end

  defp cmd(type, payload) do
    {:ok, c} = CrewProtocol.Command.new(type, payload)
    c
  end

  test "a VM found gone past its deadline, with no word from the driver, was killed at it" do
    deadline = System.os_time(:second) - 1

    assert VM.unknown_exit(%{"deadline" => deadline}, System.os_time(:millisecond)) ==
             "killed_deadline"

    assert VM.unknown_exit(%{"deadline" => deadline + 60}, System.os_time(:millisecond)) == nil
    assert VM.unknown_exit(%{}, System.os_time(:millisecond)) == nil
  end

  # The null driver keeps its guest's token beside it (dev and test only).
  defp token_of(vm_id) do
    File.read!(Path.join(CrewAgent.Config.vm_dir(CrewAgent.Config.get(), vm_id), "null-token"))
  end
end
