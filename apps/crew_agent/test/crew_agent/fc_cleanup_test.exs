defmodule CrewAgent.FirecrackerCleanupTest do
  @moduledoc """
  A VM's cleanup that fails (crew-vmctl away, a jail that won't go) is
  reported, recorded and retried, and the VM's lease and clone are kept
  until it works. Jails the agent has no record of are cleaned up at
  start. Against a fake crew-vmctl and a fake cgroup tree.
  """
  use ExUnit.Case, async: false

  import CrewAgent.TestEvents

  alias CrewAgent.{Config, FakeVmctl, Handler, Net}
  alias CrewAgent.Driver.Firecracker.Monitor
  alias CrewAgent.VMs.{Cleanup, Janitor}

  setup do
    base = Config.get()
    tmp = if match?({:unix, :darwin}, :os.type()), do: "/private/tmp", else: "/tmp"
    root = "#{tmp}/cfcc#{System.unique_integer([:positive])}"
    data = Path.join(root, "data")
    File.mkdir_p!(Path.join(data, "vms"))
    File.mkdir_p!(Path.join(root, "sys/fs/cgroup/system.slice"))

    config = %{
      base
      | driver: "firecracker",
        data_dir: data,
        vmctl_socket: Path.join(root, "vmctl.sock"),
        sys: Path.join(root, "sys")
    }

    Config.put(config)
    Monitor.reset()
    Cleanup.reset()
    path = System.get_env("PATH")
    copy_for_clone(root)

    image_id = CrewProtocol.uuid7()
    image = Path.join([data, "images", image_id])
    File.mkdir_p!(image)
    for f <- ["kernel", "rootfs.ext4", "ready"], do: File.write!(Path.join(image, f), "")

    {:ok, jails} = Agent.start_link(fn -> [] end)
    # crew-vmctl's cleanup fails until the test says otherwise.
    cleanup_works = :counters.new(1, [])
    list_fails = :counters.new(1, [])
    test = self()

    answer = fn
      %{"verb" => "cleanup"} = req ->
        send(test, {:cleanup, req["vm_id"]})

        if :counters.get(cleanup_works, 1) == 1,
          do: %{"ok" => true},
          else: %{"ok" => false, "error" => "failed", "detail" => "rm: device busy"}

      %{"verb" => "start"} ->
        if :counters.get(cleanup_works, 1) == 2,
          do: %{"ok" => false, "error" => "failed", "detail" => "systemd-run: no"},
          else: %{"ok" => true}

      %{"verb" => "status", "vm_id" => id} ->
        exited = %{
          "service_result" => "success",
          "exit_code" => "exited",
          "exit_status" => "0",
          "code" => 0,
          "at" => 1
        }

        %{"ok" => true, "vm" => %{"vm_id" => id, "state" => "gone", "exited" => exited}}

      %{"verb" => "list"} ->
        # A list that fails first, when the test asks for it.
        if :counters.get(list_fails, 1) > 0 do
          :counters.sub(list_fails, 1, 1)
          %{"ok" => false, "error" => "failed", "detail" => "systemctl: timed out"}
        else
          %{"ok" => true, "vms" => [], "jails" => Agent.get(jails, & &1)}
        end

      _ ->
        %{"ok" => true}
    end

    start_supervised!({FakeVmctl, {config.vmctl_socket, answer, self()}})
    attach()

    on_exit(fn ->
      System.put_env("PATH", path)
      Config.put(base)
      Monitor.reset()
      Cleanup.reset()
      File.rm_rf!(root)
    end)

    %{
      config: config,
      root: root,
      image_id: image_id,
      works: cleanup_works,
      jails: jails,
      list_fails: list_fails
    }
  end

  # A VM's clone is a reflink, which a CI runner's ext4 can't make. There
  # a cp that copies stands in: these tests are about the cleanup.
  defp copy_for_clone(root) do
    unless match?({:unix, :darwin}, :os.type()) or reflinks?(root) do
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      cp = Path.join(bin, "cp")

      File.write!(cp, """
      #!/bin/sh
      n=$#
      for a in "$@"; do [ "$a" = --reflink=always ] || set -- "$@" "$a"; done
      shift "$n"
      exec #{System.find_executable("cp")} "$@"
      """)

      File.chmod!(cp, 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    end
  end

  defp reflinks?(dir) do
    probe = Path.join(dir, "probe")
    File.write!(probe, "")
    args = ["--reflink=always", probe, probe <> ".clone"]
    match?({_, 0}, System.cmd("cp", args, stderr_to_stdout: true))
  end

  defp cgroup(ctx, vm_id),
    do: Path.join([ctx.root, "sys/fs/cgroup/system.slice", "crew-vm-#{vm_id}.service"])

  defp start(ctx) do
    cmd =
      start_command(%{
        "size" => %{"vcpus" => 2, "memory_mib" => 1024, "disk_gib" => 10},
        "image" => %{
          "id" => ctx.image_id,
          "version" => "0.0.0-dev",
          "arch" => "arm64",
          "manifest_sha256" => String.duplicate("0", 64)
        }
      })

    assert :ok = Handler.handle(cmd)
    vm_id = cmd.payload.vm_id
    File.mkdir_p!(cgroup(ctx, vm_id))
    vm_id
  end

  defp lease(ctx, vm_id) do
    ctx.config
    |> Config.vm_dir(vm_id)
    |> Path.join("vm.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("lease_index")
  end

  test "a failed cleanup is reported, keeps the lease and the clone, and is retried", ctx do
    vm_id = start(ctx)
    dir = Config.vm_dir(ctx.config, vm_id)
    index = lease(ctx, vm_id)

    # The VM ends; crew-vmctl can't remove its jail.
    File.rm_rf!(cgroup(ctx, vm_id))
    exited = await("vm.exited", &(&1.vm_id == vm_id), 10_000)
    assert exited.payload.cleanup == "error"
    assert_received {:cleanup, ^vm_id}

    assert Cleanup.pending?(ctx.config, vm_id)
    assert File.exists?(Path.join(dir, "rootfs.ext4"))
    assert File.exists?(Path.join(dir, "kernel"))
    assert File.exists?(Path.join(dir, "exited.json"))
    other = CrewProtocol.uuid7()
    assert {:error, :taken} = Net.claim(other, index)

    # Nor is its record swept while it's pending.
    CrewAgent.VMs.sweep_exited(-1)
    assert File.exists?(dir)

    # Retried: still failing, still pending.
    Cleanup.retry_all()
    assert_received {:cleanup, ^vm_id}
    assert Cleanup.pending?(ctx.config, vm_id)

    # Then it works: the lease and the clone go, and so does the record.
    :counters.put(ctx.works, 1, 1)
    Cleanup.retry_all()
    refute Cleanup.pending?(ctx.config, vm_id)
    refute File.exists?(Path.join(dir, "rootfs.ext4"))
    refute File.exists?(Path.join(dir, "kernel"))
    assert {:ok, _} = Net.claim(other, index)
    Net.release(other)
  end

  test "a start that fails and can't be cleaned up keeps its record and lease", ctx do
    # crew-vmctl refuses the start (2), and the cleanup after it fails.
    :counters.put(ctx.works, 1, 2)

    cmd =
      start_command(%{
        "size" => %{"vcpus" => 2, "memory_mib" => 1024, "disk_gib" => 10},
        "image" => %{
          "id" => ctx.image_id,
          "version" => "0.0.0-dev",
          "arch" => "arm64",
          "manifest_sha256" => String.duplicate("0", 64)
        }
      })

    assert {:error, "start_failed", _} = Handler.handle(cmd)
    vm_id = cmd.payload.vm_id
    assert Cleanup.pending?(ctx.config, vm_id)
    index = lease(ctx, vm_id)
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), index)

    exited =
      ctx.config
      |> Config.vm_dir(vm_id)
      |> Path.join("exited.json")
      |> File.read!()
      |> Jason.decode!()

    assert exited["reason"] == "boot_failed"

    :counters.put(ctx.works, 1, 1)
    Cleanup.retry_all()
    refute Cleanup.pending?(ctx.config, vm_id)
    assert {:ok, _} = Net.claim(other = CrewProtocol.uuid7(), index)
    Net.release(other)
  end

  test "at start a pending cleanup's lease is held before anything else can take it", ctx do
    vm_id = CrewProtocol.uuid7()
    dir = Config.vm_dir(ctx.config, vm_id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "vm.json"),
      Jason.encode!(%{"vm_id" => vm_id, "lease_index" => 4321})
    )

    File.write!(Path.join(dir, "exited.json"), ~s({"code":0,"reason":"poweroff","at":1}))
    Cleanup.failed(ctx.config, vm_id, "rm: device busy")

    Cleanup.reserve_leases()
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), 4321)
    Cleanup.retry_all()
    assert Cleanup.pending?(ctx.config, vm_id)
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), 4321)

    :counters.put(ctx.works, 1, 1)
    Cleanup.retry_all()
    assert {:ok, _} = Net.claim(other = CrewProtocol.uuid7(), 4321)
    Net.release(other)
  end

  test "jails the agent has no live or pending record of are cleaned up", ctx do
    [orphan, live, done, pending] = for _ <- 1..4, do: CrewProtocol.uuid7()

    for id <- [live, done, pending] do
      File.mkdir_p!(Config.vm_dir(ctx.config, id))
      File.write!(Path.join(Config.vm_dir(ctx.config, id), "vm.json"), ~s({"lease_index":1}))
    end

    for id <- [done, pending],
        do: File.write!(Path.join(Config.vm_dir(ctx.config, id), "exited.json"), "{}")

    Cleanup.failed(ctx.config, pending, "x")

    Agent.update(ctx.jails, fn _ -> Enum.map([orphan, live, done, pending], &%{"vm_id" => &1}) end)

    :counters.put(ctx.works, 1, 0)

    Cleanup.reconcile()
    cleaned = for {:cleanup, id} <- flush(), do: id
    # The live one is adoption's; the pending one is the retry's.
    assert Enum.sort(cleaned) == Enum.sort([orphan, done])
    # done's cleanup failed, so it's pending now.
    assert Cleanup.pending?(ctx.config, done)
  end

  defp vm_record(ctx, lease, opts) do
    vm_id = CrewProtocol.uuid7()
    dir = Config.vm_dir(ctx.config, vm_id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "vm.json"),
      Jason.encode!(%{"vm_id" => vm_id, "lease_index" => lease})
    )

    if opts[:exited], do: File.write!(Path.join(dir, "exited.json"), ~s({"at":1}))
    if opts[:pending], do: Cleanup.failed(ctx.config, vm_id, "x")
    vm_id
  end

  defp release_all(ids), do: Enum.each(ids, &Net.release/1)

  test "the janitor holds every lease before it's done starting, adoption or not", ctx do
    live = vm_record(ctx, 5001, [])
    pending = vm_record(ctx, 5002, exited: true, pending: true)
    done = vm_record(ctx, 5003, exited: true)

    # init itself, before anything else of the agent starts (the link, so
    # no vm.start), not the adoption that follows it.
    assert {:ok, _state, {:continue, _}} = Janitor.init([])
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), 5001)
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), 5002)
    assert {:ok, _} = Net.claim(other = CrewProtocol.uuid7(), 5003)
    release_all([live, pending, done, other])
  end

  test "two records holding one lease block starts until it's sorted out", ctx do
    a = vm_record(ctx, 5010, exited: true, pending: true)
    b = vm_record(ctx, 5010, exited: true, pending: true)
    assert {:ok, _, _} = Janitor.init([])

    assert {:error, "lease_conflict", why} = Handler.handle(start_command())
    assert why =~ "5010"

    # One of them is cleaned up; the next look clears the block.
    Cleanup.done(ctx.config, b)
    File.rm_rf!(Config.vm_dir(ctx.config, b))
    Cleanup.reserve_leases()
    assert Cleanup.conflicts() == []
    release_all([a, b])
  end

  test "an orphan jail is looked for every minute, its lease held until its cleanup works", ctx do
    orphan = CrewProtocol.uuid7()
    Agent.update(ctx.jails, fn _ -> [%{"vm_id" => orphan, "lease_index" => 5020}] end)
    # The first list fails (crew-vmctl busy at start).
    :counters.put(ctx.list_fails, 1, 1)

    start_supervised!({Janitor, name: nil, every_ms: 50})
    assert_receive {:cleanup, ^orphan}, 1_000
    assert_receive {:cleanup, ^orphan}, 1_000
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), 5020)

    :counters.put(ctx.works, 1, 1)
    Agent.update(ctx.jails, fn _ -> [] end)
    Process.sleep(200)
    assert {:ok, _} = Net.claim(other = CrewProtocol.uuid7(), 5020)
    release_all([other])
  end

  # A crash between writing vm.json and guest.json leaves a VM that
  # can't be adopted.
  defp unadoptable(ctx, lease) do
    vm_id = vm_record(ctx, lease, [])
    dir = Config.vm_dir(ctx.config, vm_id)
    for f <- ["rootfs.ext4", "kernel"], do: File.write!(Path.join(dir, f), "")
    Cleanup.reserve_leases()
    assert {:error, :taken} = Net.claim(CrewProtocol.uuid7(), lease)
    {vm_id, dir}
  end

  defp free?(lease) do
    other = CrewProtocol.uuid7()

    case Net.claim(other, lease) do
      {:ok, _} -> Net.release(other) && true
      _ -> false
    end
  end

  test "a VM that can't be adopted is finished like any other once its cleanup works", ctx do
    :counters.put(ctx.works, 1, 1)
    {vm_id, dir} = unadoptable(ctx, 5030)

    CrewAgent.VMs.adopt_all()
    assert_received {:cleanup, ^vm_id}
    exited = await("vm.exited", &(&1.vm_id == vm_id), 5_000)
    assert exited.payload.reason == "boot_failed"
    assert exited.payload.detail == "adopt_failed"
    assert exited.payload.cleanup == "ok"

    record = dir |> Path.join("exited.json") |> File.read!() |> Jason.decode!()
    assert record["reason"] == "boot_failed"
    refute File.exists?(Path.join(dir, "rootfs.ext4"))
    refute File.exists?(Path.join(dir, "kernel"))
    assert free?(5030)
    # Nor is it taken for live again.
    Cleanup.reserve_leases()
    assert free?(5030)
  end

  test "a VM that can't be adopted, whose cleanup fails, is kept and retried", ctx do
    {vm_id, dir} = unadoptable(ctx, 5031)

    CrewAgent.VMs.adopt_all()
    assert_received {:cleanup, ^vm_id}
    exited = await("vm.exited", &(&1.vm_id == vm_id), 5_000)
    assert exited.payload.cleanup == "error"
    assert Cleanup.pending?(ctx.config, vm_id)
    assert File.exists?(Path.join(dir, "exited.json"))
    refute free?(5031)

    :counters.put(ctx.works, 1, 1)
    Cleanup.retry_all()
    refute Cleanup.pending?(ctx.config, vm_id)
    assert free?(5031)
    Cleanup.reserve_leases()
    assert free?(5031)
  end

  test "the janitor retries pending cleanups until they work", ctx do
    vm_id = CrewProtocol.uuid7()
    File.mkdir_p!(Config.vm_dir(ctx.config, vm_id))
    File.write!(Path.join(Config.vm_dir(ctx.config, vm_id), "vm.json"), ~s({"lease_index":4322}))
    File.write!(Path.join(Config.vm_dir(ctx.config, vm_id), "exited.json"), "{}")
    Cleanup.failed(ctx.config, vm_id, "x")

    start_supervised!({Janitor, name: nil, every_ms: 50})
    assert_receive {:cleanup, ^vm_id}, 1_000
    assert_receive {:cleanup, ^vm_id}, 1_000
    assert Cleanup.pending?(ctx.config, vm_id)

    :counters.put(ctx.works, 1, 1)
    assert_receive {:cleanup, ^vm_id}, 1_000
    Process.sleep(100)
    refute Cleanup.pending?(ctx.config, vm_id)
  end

  defp flush do
    receive do
      msg -> [msg | flush()]
    after
      0 -> []
    end
  end
end
