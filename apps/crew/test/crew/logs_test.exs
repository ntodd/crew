defmodule Crew.LogsTest do
  @moduledoc "Live log capture (§16.2, §16.3): ordering, acks, gaps, epochs, segments, reads and search."
  use Crew.VMCase

  alias Crew.Logs

  @epoch "0123456789abcdef"

  setup %{box: box, repo: repo} do
    dir = Path.join(System.tmp_dir!(), "crew-logs-#{System.unique_integer([:positive])}")
    Application.put_env(:crew, :log_dir, dir)
    Application.put_env(:crew, :log_timers_ms, %{ack: 30, gap: 150})

    on_exit(fn ->
      Application.delete_env(:crew, :log_dir)
      Application.delete_env(:crew, :log_timers_ms)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Crew.Logs.Supervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(Crew.Logs.Supervisor, pid)

      File.rm_rf!(dir)
    end)

    GitHubStub.stub(github_routes(repo))
    online(box)
    id = place(box, repo)
    assert_command("vm.start")
    %{vm_id: id, dir: dir}
  end

  defp lines(range, opts \\ []) do
    for n <- range do
      %{
        "n" => n,
        "t" => 1_800_000_000_000 + n,
        "step_ref" => Keyword.get(opts, :step, "s1"),
        "text" => Keyword.get(opts, :text, "line #{n}")
      }
    end
  end

  defp log(box, vm_id, seq, lines, epoch \\ @epoch),
    do:
      agent_event(box, "vm.log", %{
        "vm_id" => vm_id,
        "epoch" => epoch,
        "seq" => seq,
        "lines" => lines
      })

  defp stored(vm_id),
    do: eventually(fn -> Logs.last_n(:vm, vm_id) end) && Logs.lines(:vm, vm_id, 1, 100_000)

  # The file is written before the row is updated, so a test can see the
  # lines while the stream is still in that query. Killing it then takes
  # the shared sandbox connection with it; let it finish first.
  defp stop_stream(vm_id) do
    [{pid, _}] = Registry.lookup(Crew.Registry, {:log_stream, vm_id})
    :sys.get_state(pid)
    DynamicSupervisor.terminate_child(Crew.Logs.Supervisor, pid)
  end

  defp await_texts(vm_id, expected) do
    eventually(fn -> Logs.lines(:vm, vm_id, 1, 100_000) |> Enum.map(& &1.text) == expected end)
  end

  test "batches are stored in order, numbered, broadcast and acked", %{
    box: box,
    vm_id: id,
    dir: dir
  } do
    Logs.subscribe(id)
    log(box, id, 1, lines(1..3))
    log(box, id, 2, lines(4..5))

    await_texts(id, ["line 1", "line 2", "line 3", "line 4", "line 5"])
    assert [%{n: 1, t: 1_800_000_000_001, step_ref: "s1"} | _] = stored(id)
    assert_receive {:log_lines, ^id, [%{n: 1} | _]}
    assert_receive {:log_lines, ^id, [%{n: 4}, %{n: 5}]}

    ack = assert_command("vm.log.ack")
    assert ack.payload.epoch == @epoch
    assert ack.payload.seq in [1, 2]
    if ack.payload.seq == 1, do: assert(assert_command("vm.log.ack").payload.seq == 2)

    vm = eventually(fn -> (vm = VMs.get!(id)) && vm.last_log_seq == 2 && vm end)
    assert vm.log_epoch == @epoch
    assert vm.last_log_n == 5
    assert File.exists?(Path.join([dir, "vm", id, "live.ndjson"]))
    # Acks and resends make no operation rows: they're notifications.
    refute Repo.exists?(
             from o in Crew.Operations.Operation,
               where: o.command in ["vm.log.ack", "vm.log.resend"]
           )
  end

  test "a gap asks for a resend, and the late batch goes in its place", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    log(box, id, 3, lines(5..6))
    resend = assert_command("vm.log.resend")
    assert resend.payload.from_seq == 2

    log(box, id, 2, lines(3..4))
    await_texts(id, Enum.map(1..6, &"line #{&1}"))
    assert Enum.map(stored(id), & &1.n) == Enum.to_list(1..6)
  end

  test "a gap that isn't filled in time is marked, and the stream goes on", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    log(box, id, 3, lines(6..7))
    await_texts(id, ["line 1", "line 2", "[3 lines lost]", "line 6", "line 7"])
  end

  test "vm.log.gone marks the lost lines at once", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    log(box, id, 4, lines(9..9))
    assert_command("vm.log.resend")
    agent_event(box, "vm.log.gone", %{"vm_id" => id, "epoch" => @epoch, "up_to_seq" => 3})
    await_texts(id, ["line 1", "line 2", "[6 lines lost]", "line 9"])
  end

  test "gone past a batch that's already here takes it, and never moves back", %{
    box: box,
    vm_id: id
  } do
    log(box, id, 1, lines(1..1))
    log(box, id, 3, lines(5..5))
    assert_command("vm.log.resend")
    # The agent's buffer expired through seq 4: 2 is gone, 3 is here, 4 too.
    log(box, id, 4, lines(6..6))
    agent_event(box, "vm.log.gone", %{"vm_id" => id, "epoch" => @epoch, "up_to_seq" => 2})
    await_texts(id, ["line 1", "[3 lines lost]", "line 5", "line 6"])
    log(box, id, 5, lines(7..7))
    await_texts(id, ["line 1", "[3 lines lost]", "line 5", "line 6", "line 7"])
    # A late timeout for the old gap changes nothing.
    Process.sleep(200)
    assert length(stored(id)) == 5
  end

  test "gone through a range holding a batch that's here: that batch goes in, the rest is marked",
       %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..1))
    log(box, id, 3, lines(5..5))
    assert_command("vm.log.resend")
    agent_event(box, "vm.log.gone", %{"vm_id" => id, "epoch" => @epoch, "up_to_seq" => 4})
    log(box, id, 5, lines(9..9))
    # How many were in seq 4 is unknown: the next batch hadn't come.
    await_texts(id, ["line 1", "[3 lines lost]", "line 5", "[some lines lost]", "line 9"])
    Process.sleep(200)

    assert Enum.map(stored(id), & &1.text) == [
             "line 1",
             "[3 lines lost]",
             "line 5",
             "[some lines lost]",
             "line 9"
           ]
  end

  test "a batch sent again after a reconnect is acked again", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    assert assert_command("vm.log.ack").payload.seq == 1
    # The ack was lost: the agent sends the batch again.
    log(box, id, 1, lines(1..2))
    assert assert_command("vm.log.ack").payload.seq == 1
    assert length(stored(id)) == 2
  end

  test "a write the row didn't record is undone at restart, so the replay isn't stored twice", %{
    box: box,
    vm_id: id
  } do
    log(box, id, 1, lines(1..2))
    await_texts(id, ["line 1", "line 2"])
    eventually(fn -> VMs.get!(id).last_log_seq == 1 end)
    stop_stream(id)

    # As if seq 2's append landed and then the row's update failed.
    committed = VMs.get!(id).log_bytes

    File.write!(Logs.path(:vm, id), ~s({"n":3,"t":1,"step_ref":"s1","text":"line 3"}\n), [:append])

    # The agent never got an ack for seq 2, so it sends it again.
    log(box, id, 2, lines(3..3))
    await_texts(id, ["line 1", "line 2", "line 3"])
    assert Enum.map(stored(id), & &1.n) == [1, 2, 3]
    assert File.stat!(Logs.path(:vm, id)).size > committed
  end

  test "a torn record at the end of the file is cut off at restart", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..1))
    await_texts(id, ["line 1"])
    stop_stream(id)
    File.write!(Logs.path(:vm, id), ~s({"n":2,"t":1,"te), [:append])

    log(box, id, 2, lines(2..2))
    await_texts(id, ["line 1", "line 2"])
  end

  test "a duplicate batch is dropped", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    log(box, id, 1, lines(1..2))
    log(box, id, 2, lines(3..3))
    await_texts(id, ["line 1", "line 2", "line 3"])
  end

  test "a new epoch restarts seq, and numbering goes on", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    log(box, id, 2, lines(3..3))
    await_texts(id, ["line 1", "line 2", "line 3"])

    # The agent adopted the VM: a new epoch, seq from 1, its own n from 1.
    log(box, id, 1, lines(1..2, text: "after"), "fedcba9876543210")
    await_texts(id, ["line 1", "line 2", "line 3", "after", "after"])
    assert Enum.map(stored(id), & &1.n) == [1, 2, 3, 4, 5]
    assert eventually(fn -> VMs.get!(id).log_epoch == "fedcba9876543210" end)
  end

  test "a restarted stream picks up where the database left off", %{box: box, vm_id: id} do
    log(box, id, 1, lines(1..2))
    await_texts(id, ["line 1", "line 2"])
    eventually(fn -> VMs.get!(id).last_log_seq == 1 end)

    [{pid, _}] = Registry.lookup(Crew.Registry, {:log_stream, id})
    DynamicSupervisor.terminate_child(Crew.Logs.Supervisor, pid)

    log(box, id, 2, lines(3..3))
    await_texts(id, ["line 1", "line 2", "line 3"])
    assert List.last(stored(id)).n == 3
  end

  describe "reads" do
    setup %{box: box, vm_id: id} do
      for seq <- 1..25, do: log(box, id, seq, lines(((seq - 1) * 100 + 1)..(seq * 100)))
      eventually(fn -> Logs.last_n(:vm, id) == 2500 end)
      :ok
    end

    test "a segment row every 1000 lines, and range reads that seek to them", %{vm_id: id} do
      segments =
        Repo.all(
          from s in "log_segments",
            where: s.source == "vm",
            select: {s.first_n, s.last_n},
            order_by: s.first_n
        )

      assert segments == [{1, 1000}, {1001, 2000}]

      assert Enum.map(Logs.lines(:vm, id, 998, 1003), & &1.n) == [
               998,
               999,
               1000,
               1001,
               1002,
               1003
             ]

      assert Enum.map(Logs.lines(:vm, id, 2498, 2600), & &1.n) == [2498, 2499, 2500]
      assert Logs.lines(:vm, id, 3000, 3010) == []
    end

    test "a read is clamped to 5000 lines and 1 MiB", %{box: box, vm_id: id} do
      assert length(Logs.lines(:vm, id, 1, 100_000)) == 2500

      big = String.duplicate("x", 60_000)

      for seq <- 26..45,
          do: log(box, id, seq, lines(((seq - 1) * 100 + 1)..((seq - 1) * 100 + 1), text: big))

      eventually(fn -> Logs.last_n(:vm, id) == 2520 end)

      read = Logs.lines(:vm, id, 2501, 2520)
      assert length(read) < 20
      assert read |> Enum.map(&byte_size(&1.text)) |> Enum.sum() <= 1_048_576
    end

    test "search: plain text without ANSI, case, regex, and its limits", %{box: box, vm_id: id} do
      log(box, id, 26, [
        %{"n" => 2501, "t" => 1, "text" => "\e[31mERROR\e[0m: boom"},
        %{"n" => 2502, "t" => 2, "text" => "error: quiet"}
      ])

      eventually(fn -> Logs.last_n(:vm, id) == 2502 end)

      assert {:ok, [2501, 2502]} = Logs.search(:vm, id, "error:", regex: false, case: false)
      assert {:ok, [2501]} = Logs.search(:vm, id, "ERROR", regex: false, case: true)
      assert {:ok, [42, 142]} = Logs.search(:vm, id, "^line 1?42$", regex: true, case: true)
      assert {:error, "bad regex" <> _} = Logs.search(:vm, id, "(", regex: true, case: true)
      assert {:ok, hits} = Logs.search(:vm, id, "line", regex: false, case: true)
      assert length(hits) == 2500
      # A pathological pattern runs out of matching budget, not out of time.
      assert {:ok, _} = Logs.search(:vm, id, "(a+)+$", regex: true, case: true)
    end
  end

  test "the index follows the stream: steps, groups, annotations", %{box: box, vm_id: id} do
    log(box, id, 1, [
      %{"n" => 1, "t" => 1, "step_ref" => "s1", "text" => "::group::Install"},
      %{"n" => 2, "t" => 2, "step_ref" => "s1", "text" => "::endgroup::"},
      %{"n" => 3, "t" => 3, "step_ref" => "s2", "text" => "::error file=a.ex,line=3::boom"}
    ])

    index = eventually(fn -> (i = Logs.index(:vm, id)) && i.annotations != [] && i end)
    assert index.steps == %{"s1" => 1, "s2" => 3}
    assert index.groups == [[1, 2, "Install"]]
    assert [%{n: 3, level: "error", file: "a.ex", line: 3}] = index.annotations
  end

  test "guest steps are kept and broadcast", %{box: box, vm_id: id} do
    Logs.subscribe(id)

    steps = [
      %{
        "ref" => "s1",
        "name" => "Run tests",
        "number" => 1,
        "status" => "in_progress",
        "started_at" => 1
      }
    ]

    agent_event(box, "vm.steps", %{"vm_id" => id, "steps" => steps})
    assert_receive {:vm_steps, ^id}
    assert [%{ref: "s1", name: "Run tests", status: "in_progress"}] = Logs.steps(id)
  end

  test "VM metrics are stored with the VM's box and job", %{box: box, vm_id: id} do
    Logs.subscribe(id)

    agent_event(box, "vm.metrics", %{
      "vm_id" => id,
      "t" => 1_800_000_000_000,
      "cpu_pct" => 42.5,
      "mem_used_mib" => 900,
      "mem_total_mib" => 8192
    })

    assert_receive {:vm_metrics, ^id}

    assert [%{t: 1_800_000_000, cpu_pct: 42.5, mem_used_mib: 900, box_id: box_id}] =
             Crew.Metrics.vm_series(id)

    assert box_id == box.id
  end
end
