defmodule CrewAgent.ConformanceTest do
  @moduledoc """
  The driver conformance suite (§11.6), against real VMs from the real
  guest image, through the agent's own start path and driver. Every
  driver must pass every item.

  Items 2 to 6, and the guest's half of 9 and 12, run inside the guest:
  the agent is in conformance mode (`CREW_CONFORMANCE=1`, here
  `conformance: true`), so crew-guest runs the image's fixed check script
  instead of the runner, and the script reports each check as a log line
  (`crew-conformance: <item> ok|fail|skip <detail>`). Each VM's checks
  are registered with `CrewAgent.Conformance.put/2` before its start.
  Items 1, 6 to 11 and the host's half of 12 are driven from here.

  Agent restarts (items 9 and 10) stop and start the whole `:crew_agent`
  application, as `systemctl restart` or a launchd restart would: the
  VMs' servers, the guest API listeners and the outbox go, and the new
  agent adopts what it finds.

  Run (excluded by default):

      # vz, on a Mac (see docs/architecture.md "Conformance results")
      CREW_REAL_IMAGE_DIR=$PWD/images/guest/out/arm64 \\
        CREW_VZ_BIN=$PWD/native/crew-vz/bin/crew-vz \\
        mix test --only conformance

      # firecracker, on a Flatcar box as root
      sudo CREW_REAL_IMAGE_DIR=... native/crew-vmctl/kvm/run.sh --conformance

  Settings:

  | Variable | |
  |---|---|
  | `CREW_REAL_IMAGE_DIR` | `Image` (or `kernel`) and `rootfs.ext4` |
  | `CREW_CONFORMANCE_DRIVER` | `vz` or `firecracker` (default: the OS's) |
  | `CREW_VZ_BIN` | vz: crew-vz, built and signed |
  | `CREW_CONFORMANCE_CACHE_MGMT`, `CREW_CONFORMANCE_CACHE_TOKEN` | the box cache's management URL and token; without them item 4's cache half is skipped |
  | `CREW_CONFORMANCE_CACHE_ADDR` | vz: the cache VM's address (`CREW_VZ_CACHE_ADDR`) |
  | `CREW_CONFORMANCE_TARGETS` | more must-not-reach targets, `label=ip:port,...` (the Mac's and host VM's addresses on ports known to be open) |
  | `CREW_CONFORMANCE_EGRESS` | the site's public IPv4, recorded as site4's egress address and probed |
  | `CREW_CONFORMANCE_KIND` | `1` to run `kind create cluster` (minutes) |
  | `CREW_CONFORMANCE_STARTS` | how many concurrent starts for item 11 (default 20) |
  """
  use ExUnit.Case, async: false

  alias CrewAgent.{Config, Conformance, Handler, Images, VMs}
  alias CrewAgent.ConformanceTest.Recorder

  @moduletag :conformance
  @moduletag timeout: 1_800_000

  # -- the box -------------------------------------------------------------------------

  setup_all do
    image_dir = System.get_env("CREW_REAL_IMAGE_DIR") || raise "CREW_REAL_IMAGE_DIR isn't set"
    default = if match?({:unix, :darwin}, :os.type()), do: "vz", else: "firecracker"
    driver = System.get_env("CREW_CONFORMANCE_DRIVER", default)
    saved = Application.get_all_env(:crew_agent)
    box = box(driver, image_dir)

    # Registered first, so a setup that fails still puts the agent back.
    on_exit(fn ->
      for vm_id <- VMs.running_ids(), do: VMs.stop(vm_id, true, 0)
      Process.sleep(2_000)
      if pid = Process.whereis(Recorder), do: Recorder.stop(pid)
      for {k, _} <- box.env, do: Application.delete_env(:crew_agent, k)
      for {k, v} <- saved, do: Application.put_env(:crew_agent, k, v)
      restart_agent()
      box.teardown.()
    end)

    for {k, v} <- box.env, do: Application.put_env(:crew_agent, k, v)
    restart_agent()
    {:ok, recorder} = Recorder.start()
    image_id = CrewProtocol.uuid7()
    :ok = Images.prepare(%{id: image_id, version: "0.0.0-dev", arch: arch()})

    if egress = System.get_env("CREW_CONFORMANCE_EGRESS"),
      do: CrewAgent.Site.record_egress(Config.get(), egress)

    # What the control plane sends at join: guests get mirrors only for
    # the hosts the last cache.config enabled.
    if box.cache.mgmt do
      {:ok, cmd} =
        CrewProtocol.Command.new("cache.config", %{
          "enabled_hosts" => CrewProtocol.Hosts.names(),
          "allowlist" => [
            "registry-1.docker.io/library/*",
            "public.ecr.aws/docker/library/*",
            "ghcr.io/actions/*",
            "mcr.microsoft.com/*"
          ],
          "rotate_ca" => false
        })

      assert :ok = Handler.handle(cmd)
    end

    IO.puts("\n  conformance on #{driver} (#{arch()}), image #{image_dir}")
    %{driver: driver, image_id: image_id, recorder: recorder, cache: box.cache, caps: box.caps}
  end

  defp box("vz", image_dir) do
    bin = System.get_env("CREW_VZ_BIN") || raise "CREW_VZ_BIN isn't set"
    # Short: Unix socket paths are capped at 104 bytes on macOS.
    dir = "/private/tmp/ccf#{rem(System.unique_integer([:positive]), 100_000)}"
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "vms"))
    sock = Path.join(dir, "vzd.sock")
    sandbox = Path.expand("../../../../native/crew-vz/sandbox.sb", __DIR__)

    daemon =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["daemon", "--socket", sock, "--data-dir", dir, "--sandbox", sandbox]
      ])

    {:os_pid, daemon_pid} = Port.info(daemon, :os_pid)
    wait_until(fn -> File.exists?(sock) end, 10_000)
    cache = cache_settings()

    env =
      [
        driver: "vz",
        data_dir: dir,
        vzd_socket: sock,
        crew_vz_bin: bin,
        dev: true,
        dev_image_dir: image_dir,
        conformance: true,
        connect: false
      ] ++
        if cache.mgmt do
          addr =
            System.get_env("CREW_CONFORMANCE_CACHE_ADDR") || raise "CREW_CONFORMANCE_CACHE_ADDR"

          [vz_cache_addr: addr, cache_mgmt_url: cache.mgmt, cache_mgmt_token: cache.token]
        else
          [vz_dns_fallback: "1.1.1.1"]
        end

    teardown = fn ->
      System.cmd("kill", [to_string(daemon_pid)])
      File.rm_rf(dir)
    end

    %{env: env, teardown: teardown, cache: cache, caps: %{conns: 1024}}
  end

  defp box("firecracker", image_dir) do
    cache = cache_settings()

    env =
      [
        driver: "firecracker",
        data_dir: System.get_env("CREW_KVM_DATA_DIR", "/srv/crew"),
        vmctl_socket: System.get_env("CREW_VMCTL_SOCKET", "/run/crew/vmctl.sock"),
        guest_api_port: 7777,
        dev: true,
        dev_image_dir: image_dir,
        conformance: true,
        connect: false
      ] ++
        if(cache.mgmt, do: [cache_mgmt_url: cache.mgmt, cache_mgmt_token: cache.token], else: [])

    %{env: env, teardown: fn -> :ok end, cache: cache, caps: %{conns: 2048}}
  end

  defp cache_settings do
    %{
      mgmt: System.get_env("CREW_CONFORMANCE_CACHE_MGMT"),
      token: System.get_env("CREW_CONFORMANCE_CACHE_TOKEN")
    }
  end

  defp restart_agent do
    _ = Application.stop(:crew_agent)
    # Config.get/0 caches in a persistent term; the new start loads it.
    :persistent_term.erase(Config)
    {:ok, _} = Application.ensure_all_started(:crew_agent)
    if pid = Process.whereis(Recorder), do: Recorder.reattach(pid)
    :ok
  end

  # -- items 1 to 6, from inside ------------------------------------------------------------

  @inside ~w(sizing disk dns https payload foreign_token isolation ipv6 spoof conntrack
             tls_clients docker buildx)

  test "items 1-6: a guest boots, fetches its payload in time, and passes the inside checks",
       ctx do
    # A: another job VM on the box, listening, for B to fail to reach.
    a = start_vm(ctx, %{"checks" => ["sizing", "listen"], "listen_port" => 9000, "hold_s" => 900})
    assert_booted(ctx, a)
    await_line(ctx, a, ~r/^crew-conformance: listening on/, 120_000)
    a_results = results(log_texts(ctx, a))
    IO.puts("  A (#{a.size["vcpus"]} vCPU, #{a.size["memory_mib"]} MiB):")
    print_results(a_results)

    checks = @inside ++ if(System.get_env("CREW_CONFORMANCE_KIND") == "1", do: ["kind"], else: [])
    stats_before = cache_stats(ctx)

    b =
      start_vm(
        ctx,
        %{
          "checks" => checks,
          "targets" => [%{"label" => "peer-vm", "ip" => a.ip, "port" => 9000} | env_targets()],
          "peers" => [a.ip],
          "foreign_tokens" => [token(ctx, a)],
          "conntrack" => %{"ip" => service_ip(), "port" => 7777, "count" => 2100}
        },
        size: %{"vcpus" => 4, "memory_mib" => 8192, "disk_gib" => 20}
      )

    boot_ms = assert_booted(ctx, b)
    IO.puts("  item 1: boot to payload #{boot_ms} ms (#{b.vm_id})")

    lines = await_done(ctx, b, 1_500_000)
    results = results(lines)
    print_results(results)

    # Item 6, the agent's side: the guest's second fetch was recorded.
    assert Recorder.events(ctx.recorder, b.vm_id, "vm.state")
           |> Enum.any?(&(Map.get(&1.payload, :detail) == "payload_refetch"))

    stats_after = cache_stats(ctx)
    cache_half(ctx, stats_before, stats_after)

    # Item 6 from the host: A's token is refused for B, and on B's own
    # channel the payload is gone.
    host_side_tokens(ctx, a, b)

    VMs.stop(a.vm_id, true, 0)
    await_exit(ctx, a)
    await_exit(ctx, b)
    assert_clean(ctx, a)
    assert_clean(ctx, b)

    failures = for r <- a_results ++ results, failed?(ctx, r), do: r
    assert failures == [], "failed: #{inspect(failures, pretty: true)}"
    assert results != []
  end

  defp failed?(_ctx, %{status: "fail"}), do: true

  # The driver's own cap: 2048 tracked connections on Firecracker, the
  # helper's max_conns on vz (the agent sends 1024).
  defp failed?(ctx, %{item: "5.conntrack", detail: detail}) do
    [_, n] = Regex.run(~r/established=(\d+)/, detail)
    String.to_integer(n) > ctx.caps.conns
  end

  # On Firecracker blocked traffic is dropped, never refused: a refusal
  # means the packet reached something that answered.
  defp failed?(%{driver: "firecracker"}, %{item: "5." <> rest, status: "ok", detail: detail}),
    do: not String.starts_with?(rest, "reach_") and detail =~ ~r/ refused$/

  defp failed?(_ctx, _r), do: false

  defp cache_half(%{cache: %{mgmt: nil}}, _before, _after),
    do: IO.puts("  item 4: no cache configured; the cache half is skipped")

  defp cache_half(_ctx, before, after_) do
    hits = fn stats, host -> get_in(host_stats(stats, host), ["hits"]) || 0 end
    misses = fn stats, host -> get_in(host_stats(stats, host), ["misses"]) || 0 end

    IO.puts(
      "  item 4: cache public.ecr.aws hits #{hits.(before, "public.ecr.aws")} -> #{hits.(after_, "public.ecr.aws")}, " <>
        "misses #{misses.(before, "public.ecr.aws")} -> #{misses.(after_, "public.ecr.aws")}; " <>
        "docker.io hits #{hits.(before, "registry-1.docker.io")} -> #{hits.(after_, "registry-1.docker.io")}"
    )

    assert hits.(after_, "public.ecr.aws") > hits.(before, "public.ecr.aws"),
           "the second pull wasn't a cache hit"
  end

  defp host_stats(stats, host), do: Enum.find(stats["hosts"] || [], &(&1["host"] == host)) || %{}

  defp host_side_tokens(%{driver: "vz"} = ctx, a, b) do
    sock_b = Path.join(Config.vm_dir(Config.get(), b.vm_id), "guest.sock")

    get = fn sock, token ->
      Req.get!("http://localhost/v1/payload",
        unix_socket: sock,
        auth: {:bearer, token},
        retry: false
      ).status
    end

    assert get.(sock_b, token(ctx, a)) == 401
    assert get.(sock_b, token(ctx, b)) == 410
    IO.puts("  item 6 (host): A's token on B's socket 401, B's own refetch 410")
  end

  defp host_side_tokens(%{driver: "firecracker"} = ctx, a, _b) do
    # From the host's own address: the source isn't A's lease.
    status =
      Req.get!("http://#{service_ip()}:7777/v1/payload",
        auth: {:bearer, token(ctx, a)},
        retry: false
      ).status

    assert status == 401
    IO.puts("  item 6 (host): A's token from the host's address 401")
  end

  # -- item 2 across sizes ------------------------------------------------------------------------

  test "items 2-3 across sizes: vCPUs, memory and disk as sized", ctx do
    # One at a time, so the largest fits on a 16 GiB host VM.
    sizes = [
      %{"vcpus" => 1, "memory_mib" => 1024, "disk_gib" => 10},
      %{"vcpus" => 2, "memory_mib" => 2048, "disk_gib" => 20},
      %{"vcpus" => 4, "memory_mib" => 4096, "disk_gib" => 40},
      %{"vcpus" => 4, "memory_mib" => 8192, "disk_gib" => 40}
    ]

    results =
      Enum.flat_map(sizes, fn size ->
        vm = start_vm(ctx, %{"checks" => ["sizing", "disk"]}, size: size)
        r = results(await_done(ctx, vm, 300_000))

        IO.puts(
          "  #{vm.size["vcpus"]} vCPU, #{vm.size["memory_mib"]} MiB, #{vm.size["disk_gib"]} GiB:"
        )

        print_results(r)
        await_exit(ctx, vm)
        assert_clean(ctx, vm)
        r
      end)

    failures = for r <- results, failed?(ctx, r), do: r
    assert failures == [], "failed: #{inspect(failures, pretty: true)}"
  end

  # -- item 7: stopping ------------------------------------------------------------------------

  test "item 7: a graceful stop powers off within 10 s; a forced one within 2 s", ctx do
    hold = %{"checks" => [], "hold_s" => 900}
    g = start_vm(ctx, hold)
    f = start_vm(ctx, hold)
    await_line(ctx, g, ~r/^crew-conformance: done/, 120_000)
    await_line(ctx, f, ~r/^crew-conformance: done/, 120_000)

    graceful = time_until_gone(ctx, g, fn -> VMs.stop(g.vm_id, false, 30) end)
    forced = time_until_gone(ctx, f, fn -> VMs.stop(f.vm_id, true, 0) end)
    IO.puts("  item 7: graceful stop #{graceful} ms, forced #{forced} ms")

    assert await_exit(ctx, g).payload.reason == "poweroff"
    assert await_exit(ctx, f).payload.reason == "killed_stop"
    assert graceful <= 10_000
    assert forced <= 2_000
    assert_clean(ctx, g)
    assert_clean(ctx, f)
  end

  # -- items 9 and 10: the agent goes away ----------------------------------------------------------

  test "item 9: an agent restart mid-job adopts the VM, and its lines go on in a new epoch",
       ctx do
    vm = start_vm(ctx, %{"checks" => ["ticks"], "ticks" => 400, "hold_s" => 600})
    await_line(ctx, vm, ~r/^crew-conformance: tick 50\//, 120_000)
    [first | _] = Recorder.events(ctx.recorder, vm.vm_id, "vm.log")
    old_epoch = first.payload.epoch

    down = System.monotonic_time(:millisecond)
    _ = Application.stop(:crew_agent)
    Process.sleep(5_000)
    assert driver_alive?(ctx, vm), "the VM went with the agent"
    restart_agent()
    IO.puts("  item 9: agent down #{System.monotonic_time(:millisecond) - down} ms")

    await_line(ctx, vm, ~r/^crew-conformance: 9.ticks ok/, 120_000)
    logs = Recorder.events(ctx.recorder, vm.vm_id, "vm.log")
    epochs = logs |> Enum.map(& &1.payload.epoch) |> Enum.uniq()
    assert [^old_epoch, new_epoch] = epochs
    assert new_epoch != old_epoch

    lines = Enum.flat_map(logs, & &1.payload.lines)
    ns = Enum.map(lines, & &1.n)
    # Numbering goes on across the epochs, with no line twice.
    assert ns == Enum.sort(ns)
    assert ns == Enum.uniq(ns)

    ticks =
      for l <- lines,
          [_, i] <- [Regex.run(~r/^crew-conformance: tick (\d+)\//, l.text)],
          do: String.to_integer(i)

    missing = Enum.to_list(1..400) -- ticks

    if missing != [] do
      for e <- logs do
        p = e.payload
        texts = Enum.map(p.lines, & &1.text)

        IO.puts(
          "    vm.log epoch #{p.epoch} seq #{p.seq} n #{hd(p.lines).n}..#{List.last(p.lines).n}: " <>
            "#{inspect(hd(texts))} .. #{inspect(List.last(texts))}"
        )
      end
    end

    IO.puts(
      "  item 9: epochs #{inspect(epochs)}, #{length(ticks)} of 400 ticks, missing #{inspect(missing)}"
    )

    assert missing == [], "lines lost across the restart: #{inspect(missing)}"

    VMs.stop(vm.vm_id, true, 0)
    await_exit(ctx, vm)
    assert_clean(ctx, vm)
  end

  test "item 10: a VM past its deadline is killed while the agent is down", ctx do
    vm = start_vm(ctx, %{"checks" => [], "hold_s" => 900}, deadline: System.os_time(:second) + 45)
    await_line(ctx, vm, ~r/^crew-conformance: done/, 120_000)

    _ = Application.stop(:crew_agent)
    t0 = System.monotonic_time(:millisecond)
    wait_until(fn -> not driver_alive?(ctx, vm) end, 120_000)

    IO.puts(
      "  item 10: killed #{System.monotonic_time(:millisecond) - t0} ms into the agent's absence"
    )

    assert {:ok, %{reason: "killed_deadline"}} = driver(ctx).exit_status(vm.vm_id)

    restart_agent()
    exited = await_exit(ctx, vm)
    assert exited.payload.reason == "killed_deadline"
    assert_clean(ctx, vm)
  end

  # -- item 11: twenty at once ------------------------------------------------------------------------

  test "item 11: twenty concurrent starts all boot", ctx do
    n = String.to_integer(System.get_env("CREW_CONFORMANCE_STARTS", "20"))
    size = %{"vcpus" => 1, "memory_mib" => 1024, "disk_gib" => 10}

    vms =
      1..n
      |> Task.async_stream(
        fn _ -> start_vm(ctx, %{"checks" => [], "hold_s" => 900}, size: size) end,
        max_concurrency: n,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, vm} -> vm end)

    booted = Enum.map(vms, &assert_booted(ctx, &1, 180_000))
    ready = Enum.map(vms, &ready_ms(ctx, &1, 300_000))

    IO.puts(
      "  item 11: #{n} starts; to payload p50 #{pct(booted, 50)} ms, p95 #{pct(booted, 95)} ms, max #{Enum.max(booted)} ms"
    )

    IO.puts(
      "  item 11: to ready (where the runner would start) p50 #{pct(ready, 50)} ms, p95 #{pct(ready, 95)} ms, max #{Enum.max(ready)} ms"
    )

    for vm <- vms, do: VMs.stop(vm.vm_id, true, 0)
    for vm <- vms, do: await_exit(ctx, vm)
    for vm <- vms, do: assert_clean(ctx, vm)
  end

  # -- item 12: hostile guests --------------------------------------------------------------------------

  test "item 12: a console flood leaves console.log at 8 MiB or less", ctx do
    vm = start_vm(ctx, %{"checks" => ["console_flood"], "console_mib" => 100, "hold_s" => 30})
    path = console_path(ctx, vm)
    sampler = Task.async(fn -> sample_max(path, vm, ctx) end)
    lines = await_done(ctx, vm, 1_200_000)
    print_results(results(lines))
    Process.sleep(2_000)
    max_seen = Task.await(sampler, 60_000)
    size = File.stat!(path).size
    IO.puts("  item 12: console.log #{size} bytes after the flood (largest seen #{max_seen})")
    assert size <= 8 * 1024 * 1024
    VMs.stop(vm.vm_id, true, 0)
    await_exit(ctx, vm)
  end

  test "item 12: a guest flooding /v1/log, /v1/steps and /v1/state is held to the caps", ctx do
    limit = 4 * 1024 * 1024
    vm = start_vm(ctx, %{"checks" => ["api_flood"]}, log_limit_bytes: limit)
    # Past the limit the guest's lines stop for good, its `done` among
    # them: it powers off when the flood is over.
    await_exit(ctx, vm, 300_000)
    print_results(results(log_texts(ctx, vm)))

    logs = Recorder.events(ctx.recorder, vm.vm_id, "vm.log")
    all = Enum.flat_map(logs, & &1.payload.lines)
    bytes = all |> Enum.map(&byte_size(&1.text)) |> Enum.sum()
    markers = Enum.count(all, &(&1.text =~ "live log reached its limit"))
    steps = Recorder.events(ctx.recorder, vm.vm_id, "vm.steps")
    states = Recorder.events(ctx.recorder, vm.vm_id, "vm.state")

    span = fn evs ->
      case evs do
        [] -> 0
        _ -> (List.last(evs).at - hd(evs).at) / 1000
      end
    end

    IO.puts(
      "  item 12: log #{bytes} bytes in #{length(logs)} vm.log (limit #{limit}), #{markers} marker; " <>
        "#{length(steps)} vm.steps over #{Float.round(span.(steps), 1)} s; #{length(states)} vm.state"
    )

    assert bytes <= limit + 1024
    assert markers == 1
    # At most one vm.steps a second, coalesced.
    assert length(steps) <= trunc(span.(steps)) + 2
    assert length(states) <= 20
    assert_clean(ctx, vm)
  end

  # -- starting VMs -----------------------------------------------------------------------------------

  defp start_vm(ctx, params, opts \\ []) do
    size = Keyword.get(opts, :size, %{"vcpus" => 2, "memory_mib" => 2048, "disk_gib" => 10})

    overrides =
      %{
        "size" => size,
        "image" => %{
          "id" => ctx.image_id,
          "version" => "0.0.0-dev",
          "arch" => arch(),
          "manifest_sha256" => String.duplicate("0", 64)
        },
        "deadline" => Keyword.get(opts, :deadline, System.os_time(:second) + 3600),
        "log_limit_bytes" => Keyword.get(opts, :log_limit_bytes, 104_857_600)
      }

    cmd = CrewAgent.TestEvents.start_command(overrides)
    vm_id = cmd.payload.vm_id
    :ok = Conformance.put(vm_id, params)
    t0 = System.os_time(:millisecond)
    Recorder.started(ctx.recorder, vm_id, t0)
    assert :ok = Handler.handle(cmd)
    lease = read_json(ctx, vm_id, "vm.json")["lease_index"]
    %{vm_id: vm_id, t0: t0, lease: lease, ip: CrewAgent.Net.lease(lease).guest, size: size}
  end

  defp assert_booted(ctx, vm, timeout \\ 60_000) do
    ev =
      Recorder.await(ctx.recorder, vm.vm_id, timeout, fn e ->
        e.type == "vm.state" and e.payload.state == "booted" and
          is_nil(Map.get(e.payload, :detail))
      end) || flunk("#{vm.vm_id} didn't fetch its payload within #{timeout} ms")

    ms = ev.at - vm.t0
    assert ms <= 60_000, "boot to payload took #{ms} ms"
    ms
  end

  defp ready_ms(ctx, vm, timeout) do
    ev =
      Recorder.await(ctx.recorder, vm.vm_id, timeout, fn e ->
        e.type == "vm.state" and e.payload.state == "runner_listening"
      end) || flunk("#{vm.vm_id} never got ready")

    ev.at - vm.t0
  end

  defp await_line(ctx, vm, re, timeout) do
    Recorder.await(ctx.recorder, vm.vm_id, timeout, fn e ->
      e.type == "vm.log" and Enum.any?(e.payload.lines, &(&1.text =~ re))
    end) ||
      flunk("""
      #{vm.vm_id}: no line matching #{inspect(re)} within #{timeout} ms
      events: #{inspect(for e <- GenServer.call(ctx.recorder, :events), e.vm_id == vm.vm_id, do: e.type)}
      console (last 3 KiB):
      #{console_tail(ctx, vm)}
      """)
  end

  defp console_tail(ctx, vm) do
    case File.read(console_path(ctx, vm)) do
      {:ok, text} -> binary_part(text, max(byte_size(text) - 3072, 0), min(byte_size(text), 3072))
      {:error, reason} -> "(#{reason})"
    end
  end

  defp await_done(ctx, vm, timeout) do
    await_line(ctx, vm, ~r/^crew-conformance: done /, timeout)
    log_texts(ctx, vm)
  end

  defp log_texts(ctx, vm) do
    ctx.recorder
    |> Recorder.events(vm.vm_id, "vm.log")
    |> Enum.flat_map(& &1.payload.lines)
    |> Enum.map(& &1.text)
  end

  defp await_exit(ctx, vm, timeout \\ 60_000) do
    Recorder.await(ctx.recorder, vm.vm_id, timeout, &(&1.type == "vm.exited")) ||
      flunk("#{vm.vm_id} didn't exit within #{timeout} ms")
  end

  defp time_until_gone(ctx, vm, fun) do
    t0 = System.monotonic_time(:millisecond)
    fun.()
    wait_until(fn -> not driver_alive?(ctx, vm) end, 60_000, 50)
    System.monotonic_time(:millisecond) - t0
  end

  # -- results ------------------------------------------------------------------------------------------

  @line ~r/^crew-conformance: (\S+) (ok|fail|skip|info) ?(.*)$/

  defp results(lines) do
    for l <- lines,
        [_, item, status, detail] <- [Regex.run(@line, l)],
        do: %{item: item, status: status, detail: detail}
  end

  defp print_results(results) do
    for r <- results, do: IO.puts("    #{r.item} #{r.status} #{r.detail}")
  end

  defp env_targets do
    "CREW_CONFORMANCE_TARGETS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(fn entry ->
      [label, rest] = String.split(String.trim(entry), "=", parts: 2)
      [ip, port] = String.split(rest, ":")
      %{"label" => label, "ip" => ip, "port" => String.to_integer(port)}
    end)
  end

  defp cache_stats(%{cache: %{mgmt: nil}}), do: %{}

  defp cache_stats(_ctx) do
    {:ok, stats} = CrewAgent.Cache.stats(Config.get())
    stats
  end

  # -- item 8: nothing left ------------------------------------------------------------------------------

  defp assert_clean(%{driver: "vz"} = ctx, vm) do
    refute driver_alive?(ctx, vm)
    {out, _} = System.cmd("pgrep", ["-f", vm.vm_id])
    assert String.trim(out) == "", "a process for #{vm.vm_id} is left: #{out}"
    dir = Config.vm_dir(Config.get(), vm.vm_id)

    for f <- ~w(rootfs.ext4 vz.json guest.sock ctl.sock),
        do: refute(File.exists?(Path.join(dir, f)), f)

    swept(vm)
  end

  defp assert_clean(%{driver: "firecracker"} = ctx, vm) do
    alias CrewAgent.Driver.Firecracker
    refute driver_alive?(ctx, vm)

    assert {:ok, %{"vm" => %{"state" => "gone"}}} =
             Firecracker.vmctl(%{"verb" => "status", "vm_id" => vm.vm_id})

    refute File.exists?("/sys/class/net/crewt#{vm.lease}"), "the tap is still there"
    {pairs, 0} = System.cmd("nft", ["-j", "list", "set", "inet", "crew", "vm_pairs"])
    refute pairs =~ "\"crewt#{vm.lease}\"", "its vm_pairs element is still there"
    refute File.exists?(Path.join([Config.get().data_dir, "jail", "firecracker", vm.vm_id]))
    # Its unit: crew-vmctl's status above ("gone"), and run.sh lists
    # crew-vm-* units once the suite is done.
    dir = Config.vm_dir(Config.get(), vm.vm_id)
    for f <- ~w(rootfs.ext4 kernel fc.json), do: refute(File.exists?(Path.join(dir, f)), f)
    swept(vm)
  end

  # The agent keeps the VM's record (vm.json, exited.json, its console)
  # for the inventory; the sweep takes the rest.
  # (The sweep takes every exited VM's: another VM's check may have
  # swept this one already.)
  defp swept(vm) do
    dir = Config.vm_dir(Config.get(), vm.vm_id)

    left =
      case File.ls(dir) do
        {:ok, files} -> Enum.join(Enum.sort(files), " ")
        {:error, :enoent} -> "(swept already)"
      end

    Process.sleep(5)
    VMs.sweep_exited(0)
    refute File.exists?(dir), "the sweep left #{dir}"
    IO.puts("  item 8: #{String.slice(vm.vm_id, -8, 8)} clean; its record held #{left}")
  end

  # -- helpers ------------------------------------------------------------------------------------------

  defp driver(%{driver: "vz"}), do: CrewAgent.Driver.VZ
  defp driver(%{driver: "firecracker"}), do: CrewAgent.Driver.Firecracker
  defp driver_alive?(ctx, vm), do: driver(ctx).alive?(vm.vm_id)

  defp read_json(_ctx, vm_id, file),
    do: Config.get() |> Config.vm_dir(vm_id) |> Path.join(file) |> File.read!() |> Jason.decode!()

  # The token is on the VM's kernel command line, which the agent wrote
  # into the driver's config.
  defp token(%{driver: "vz"} = ctx, vm),
    do: cmdline_token(read_json(ctx, vm.vm_id, "vz.json")["cmdline"])

  defp token(%{driver: "firecracker"} = ctx, vm),
    do: cmdline_token(read_json(ctx, vm.vm_id, "fc.json")["boot-source"]["boot_args"])

  defp cmdline_token(cmdline),
    do: hd(Regex.run(~r/crew\.token=(\S+)/, cmdline, capture: :all_but_first))

  defp console_path(%{driver: "vz"}, vm),
    do: Path.join(Config.vm_dir(Config.get(), vm.vm_id), "console.log")

  defp console_path(%{driver: "firecracker"}, vm),
    do: Path.join([Config.get().data_dir, "jail", "firecracker", vm.vm_id, "console.log"])

  defp sample_max(path, vm, ctx, max \\ 0) do
    size =
      case File.stat(path) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end

    done? =
      Recorder.events(ctx.recorder, vm.vm_id, "vm.log")
      |> Enum.any?(fn e ->
        Enum.any?(e.payload.lines, &(&1.text =~ ~r/^crew-conformance: done/))
      end)

    if done? do
      max(max, size)
    else
      Process.sleep(100)
      sample_max(path, vm, ctx, max(max, size))
    end
  end

  defp service_ip, do: Config.get().service_ip

  defp arch do
    if :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64"),
      do: "arm64",
      else: "x64"
  end

  defp pct(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(0, ceil(length(sorted) * p / 100) - 1))
  end

  defp wait_until(fun, ms, step \\ 250) do
    cond do
      fun.() -> :ok
      ms <= 0 -> flunk("timed out")
      true -> Process.sleep(step) && wait_until(fun, ms - step, step)
    end
  end
end

defmodule CrewAgent.ConformanceTest.Recorder do
  @moduledoc """
  The control plane's side, for the suite: attached to the agent's
  outbox, it keeps every event with the time it came, acks the reliable
  ones, and acks each log batch (`vm.log.ack`) as the control plane does.
  """
  use GenServer

  def start, do: GenServer.start(__MODULE__, nil, name: __MODULE__)
  def stop(pid), do: GenServer.stop(pid)
  def reattach(pid), do: GenServer.call(pid, :attach)
  def started(pid, vm_id, t0), do: GenServer.call(pid, {:started, vm_id, t0})

  def events(pid, vm_id, type),
    do: GenServer.call(pid, :events) |> Enum.filter(&(&1.vm_id == vm_id and &1.type == type))

  @doc "Waits for an event of the VM's matching `fun`; nil after `timeout`."
  def await(pid, vm_id, timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(pid, vm_id, fun, deadline)
  end

  defp poll(pid, vm_id, fun, deadline) do
    found = GenServer.call(pid, :events) |> Enum.find(&(&1.vm_id == vm_id and fun.(&1)))

    cond do
      found -> found
      System.monotonic_time(:millisecond) > deadline -> nil
      true -> Process.sleep(100) && poll(pid, vm_id, fun, deadline)
    end
  end

  @impl true
  def init(nil) do
    :ok = CrewAgent.Outbox.attach(self())
    {:ok, %{events: [], started: %{}}}
  end

  @impl true
  def handle_call(:attach, _from, s), do: {:reply, CrewAgent.Outbox.attach(self()), s}

  def handle_call({:started, vm_id, t0}, _from, s),
    do: {:reply, :ok, put_in(s.started[vm_id], t0)}

  def handle_call(:events, _from, s), do: {:reply, Enum.reverse(s.events), s}

  @impl true
  def handle_info({:outbox_deliver, %CrewProtocol.Event{type: type, payload: p}, ack}, s) do
    if ack, do: CrewAgent.Outbox.ack(ack)
    at = System.os_time(:millisecond)

    if type == "vm.log",
      do: spawn(fn -> CrewAgent.VMs.log_ack(p.vm_id, p.epoch, p.seq) end)

    {:noreply, %{s | events: [%{type: type, vm_id: p[:vm_id], payload: p, at: at} | s.events]}}
  end

  def handle_info(_msg, s), do: {:noreply, s}
end
