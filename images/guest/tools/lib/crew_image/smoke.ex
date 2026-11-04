defmodule CrewImage.Smoke do
  @moduledoc """
  Boots the built guest image on this Mac the way a vz box will
  (docs/crew_spec.md §13; native/crew-vz/README.md): `crew-vz daemon`, a
  VM directory with `vz.json` and an APFS clone of the rootfs grown to the
  VM's disk, and a fake guest API (`CrewImage.Smoke.GuestAPI`) on the
  VM's `guest.sock`. The kernel command line is §13.3's for arm64 on vz,
  plus `systemd.journald.forward_to_console=1` so the journal (crew-guest,
  Docker, the runner's output) lands in `console.log`.

  Two boots:

  1. **job**: the guest API serves a payload whose JIT config decodes to
     `DisableUpdate: true` (and a cache CA, so that path runs too). It
     passes when crew-guest fetches the payload, Docker comes up and
     crew-guest starts the runner. The runner can't authenticate with a
     fake config; whatever it prints is reported. If the VM is still up
     after that, the power button stops it.
  2. **stop**: the payload is withheld (crew-guest keeps asking), and the
     power button is pressed once logind watches it. It passes when the
     guest powers off cleanly.

  Times are from the `start` request (host clock) and from the guest's
  own uptime stamps on console lines.
  """

  require Logger

  alias CrewImage.Smoke.{FakeJIT, GuestAPI, VZD}

  @markers [
    crew_guest: "vm mode, API",
    docker: "API listen on /run/docker.sock",
    runner_started: "crew-guest: started the runner",
    runner_output: "runner: ",
    runner_exited: "crew-guest: the runner exited",
    logind: "Watching system buttons on",
    power_key: "Power key pressed",
    startup: "Startup finished in"
  ]

  def run(opts) do
    bin = Keyword.fetch!(opts, :crew_vz)
    data = mkdtemp!()
    Logger.info("smoke: data dir #{data}")

    File.mkdir_p!(Path.join(data, "images/smoke"))
    kernel = Path.join(data, "images/smoke/Image")
    clone!(Keyword.fetch!(opts, :kernel), kernel)

    {:ok, vzd} = VZD.start(bin, data)

    try do
      job = boot(:job, vzd, data, kernel, opts)
      stop = boot(:stop, vzd, data, kernel, opts)
      results = [job, stop]
      ok = Enum.all?(results, & &1.ok)
      # A failed run's VM directories are kept for inspection.
      if ok and !opts[:keep], do: File.rm_rf(data)
      %{ok: ok, results: results, data: data}
    after
      VZD.stop(vzd)
    end
  end

  # One VM, start to exit.
  defp boot(kind, vzd, data, kernel, opts) do
    vm_id = "smoke-#{kind}"
    dir = Path.join([data, "vms", vm_id])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o750)
    disk = Path.join(dir, "rootfs.ext4")
    clone!(Keyword.fetch!(opts, :rootfs), disk)
    {_, 0} = System.cmd("truncate", ["-s", "#{Keyword.get(opts, :disk_gib, 20)}G", disk])

    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    payload = if kind == :job, do: payload(opts), else: :withhold
    {:ok, api} = GuestAPI.start_link(token: token, payload: payload)
    sock = Path.join(dir, "guest.sock")

    {:ok, server} =
      Bandit.start_link(
        plug: {GuestAPI.Plug, api},
        scheme: :http,
        ip: {:local, sock},
        port: 0,
        startup_log: false
      )

    write_config!(dir, vm_id, kernel, disk, token, opts)
    console = Path.join(dir, "console.log")

    t0 = System.monotonic_time(:millisecond)
    deadline = System.os_time(:second) + 600
    {:ok, started} = VZD.call(vzd.sock, %{op: "start", vm_id: vm_id, deadline: deadline})
    start_ms = System.monotonic_time(:millisecond) - t0

    result =
      if started["ok"] do
        watch(kind, %{vzd: vzd, vm_id: vm_id, api: api, console: console, t0: t0}, opts)
      else
        %{ok: false, problems: ["start failed: #{inspect(started)}"]}
      end

    Supervisor.stop(server)
    events = GuestAPI.events(api)
    GenServer.stop(api)

    finish(kind, vm_id, result, events, File.read!(console), t0)
    |> Map.merge(%{kind: kind, start_ms: start_ms, dir: dir})
  end

  # Follows the boot until the scenario's end, pressing the power button
  # when it's time.
  defp watch(:job, ctx, opts) do
    wait = Keyword.get(opts, :runner_wait_s, 45) * 1000

    cond do
      not until(ctx, 180_000, &seen?(&1, :runner_started)) ->
        Map.put(exit_or_kill(ctx), :problems, ["the runner never started"])

      # The runner gets time to show what it makes of the fake config. If
      # it exits, crew-guest reports job_finished and powers off by itself.
      until(ctx, wait, &(exited?(&1) or seen?(&1, :runner_exited))) and
          until(ctx, 30_000, &exited?/1) ->
        %{exit: exit_record(ctx), powered_off_itself: true}

      true ->
        press_and_wait(ctx)
    end
  end

  # Pressed while crew-guest waits for its payload, a second after it's up:
  # the stop a VM that never got its job would see.
  defp watch(:stop, ctx, _opts) do
    if until(ctx, 60_000, &(seen?(&1, :logind) and seen?(&1, :crew_guest))) do
      until(ctx, 1_000, fn _ -> false end)
      press_and_wait(ctx)
    else
      Map.put(exit_or_kill(ctx), :problems, ["logind or crew-guest never came up"])
    end
  end

  defp press_and_wait(ctx) do
    pressed = System.monotonic_time(:millisecond)
    {:ok, resp} = VZD.call(ctx.vzd.sock, %{op: "stop", vm_id: ctx.vm_id})

    if resp["ok"] do
      until(ctx, 30_000, &exited?/1)
      exit_ms = System.monotonic_time(:millisecond) - pressed
      Map.merge(exit_or_kill(ctx), %{pressed_at: pressed - ctx.t0, stop_ms: exit_ms})
    else
      Map.merge(exit_or_kill(ctx), %{problems: ["stop refused: #{inspect(resp)}"]})
    end
  end

  defp exit_or_kill(ctx) do
    unless exited?(ctx) do
      VZD.call(ctx.vzd.sock, %{op: "stop", vm_id: ctx.vm_id, force: true})
    end

    %{exit: exit_record(ctx)}
  end

  defp exit_record(ctx) do
    case VZD.status(ctx.vzd.sock, ctx.vm_id) do
      {:ok, %{"vm" => %{"exited" => rec}}} -> rec
      other -> other
    end
  end

  defp exited?(ctx) do
    match?({:ok, %{"vm" => %{"state" => "exited"}}}, VZD.status(ctx.vzd.sock, ctx.vm_id))
  end

  defp seen?(ctx, marker), do: String.contains?(read(ctx.console), @markers[marker])

  defp until(ctx, ms, fun) do
    deadline = System.monotonic_time(:millisecond) + ms
    poll(ctx, deadline, fun)
  end

  defp poll(ctx, deadline, fun) do
    observe(ctx)

    cond do
      fun.(ctx) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        poll(ctx, deadline, fun)
    end
  end

  # When the host first saw each marker in console.log, in ms from `start`
  # (to within the 50 ms poll).
  defp observe(ctx) do
    text = read(ctx.console)
    now = System.monotonic_time(:millisecond) - ctx.t0

    seen =
      Enum.reduce(@markers, Process.get({:seen, ctx.vm_id}, %{}), fn {name, marker}, acc ->
        if not Map.has_key?(acc, name) and String.contains?(text, marker),
          do: Map.put(acc, name, now),
          else: acc
      end)

    Process.put({:seen, ctx.vm_id}, seen)
  end

  # The verdict and the numbers.
  defp finish(kind, vm_id, result, events, console, t0) do
    marks =
      for {name, text} <- @markers, into: %{} do
        {name, uptime_of(console, text)}
      end

    host_seen = Process.delete({:seen, vm_id}) || %{}

    payloads = Enum.filter(events, &(&1.kind == :payload))
    states = for %{kind: :state, data: d} <- events, do: d
    logs = for %{kind: :log, data: lines} <- events, line <- lines, do: line.text

    runner_lines =
      console
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "runner: "))
      |> Enum.map(&(String.split(&1, "runner: ", parts: 2) |> List.last()))

    exit = result[:exit] || %{}

    problems =
      (result[:problems] || []) ++
        check(kind, %{
          payloads: payloads,
          marks: marks,
          logs: logs,
          exit: exit,
          console: console,
          result: result
        })

    %{
      ok: problems == [],
      problems: problems,
      payload_ms: Enum.map(payloads, &(&1.at - t0)) |> List.first(),
      marks: marks,
      host_seen: host_seen,
      states: states,
      guest_logs: logs,
      runner_lines: runner_lines,
      exit: exit,
      stop_ms: result[:stop_ms]
    }
  end

  defp check(:job, r) do
    failures([
      {length(r.payloads) == 1, "the payload was fetched #{length(r.payloads)} times"},
      {r.marks.docker != nil, "Docker never came up"},
      {r.marks.runner_started != nil, "crew-guest never started the runner"},
      {r.marks.runner_output != nil, "the runner printed nothing"},
      {not Enum.any?(r.logs, &(&1 =~ "refusing to start the runner")),
       "crew-guest refused the JIT config"},
      {not Enum.any?(r.logs, &(&1 =~ ~r/ failed/)),
       "a boot step failed (see the guest's log lines)"},
      {r.exit["code"] == 0, "the VM exited with #{inspect(r.exit)}"}
    ])
  end

  defp check(:stop, r) do
    stop_ms = r.result[:stop_ms]

    failures([
      {r.marks.power_key != nil, "the guest never saw the power button"},
      {r.exit["code"] == 0, "the VM exited with #{inspect(r.exit)}"},
      {r.exit["detail"] == "stop requested",
       "the exit wasn't the requested stop: #{inspect(r.exit)}"},
      {is_integer(stop_ms) and stop_ms < 20_000, "the graceful stop took #{inspect(stop_ms)} ms"}
    ])
  end

  defp failures(checks), do: for({false, message} <- checks, do: message)

  # The guest's uptime (s) on the first console line containing text.
  defp uptime_of(console, text) do
    console
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.contains?(line, text) do
        case Regex.run(~r/^\[\s*(\d+\.\d+)\]/, line) do
          [_, t] -> String.to_float(t)
          _ -> :seen
        end
      end
    end)
  end

  defp payload(opts) do
    %{
      "jit_config" => FakeJIT.build(name: "crew-smoke"),
      "ca_pem" => test_ca(),
      "policy" => %{"fork_prs" => "refuse", "repo_full_name" => "ntodd/crew"},
      "size" => %{
        "vcpus" => Keyword.get(opts, :vcpus, 4),
        "memory_mib" => Keyword.get(opts, :memory_mib, 4096),
        "disk_gib" => Keyword.get(opts, :disk_gib, 20)
      },
      "labels" => ["crew"]
    }
  end

  defp test_ca do
    %{cert: der} = :public_key.pkix_test_root_cert(~c"Crew smoke-test cache CA", [])
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp write_config!(dir, vm_id, kernel, disk, token, opts) do
    cmdline =
      Enum.join(
        [
          "console=hvc0 panic=1 quiet loglevel=4",
          "root=/dev/vda rw rootfstype=ext4",
          "ip=10.200.0.2::10.200.0.1:255.255.255.252::eth0:off",
          "crew.vm=#{vm_id} crew.token=#{token} crew.api=http://10.199.0.1:7777",
          "systemd.journald.forward_to_console=1"
        ],
        " "
      )

    cfg = %{
      "vm_id" => vm_id,
      "vcpus" => Keyword.get(opts, :vcpus, 4),
      "memory_mib" => Keyword.get(opts, :memory_mib, 4096),
      "kernel" => kernel,
      "cmdline" => cmdline,
      "disk" => disk,
      "console_log" => Path.join(dir, "console.log"),
      "guest_socket" => Path.join(dir, "guest.sock"),
      "ctl_socket" => Path.join(dir, "ctl.sock"),
      "exited_path" => Path.join(dir, "exited.json"),
      "lease" => %{
        "gateway" => "10.200.0.1/30",
        "guest" => "10.200.0.2/30",
        "mac" => "02:00:0a:c8:00:02"
      },
      "service_ip" => "10.199.0.1",
      "dns_fallback" => "1.1.1.1:53"
    }

    File.write!(Path.join(dir, "vz.json"), Jason.encode!(cfg, pretty: true))
    File.chmod!(Path.join(dir, "vz.json"), 0o640)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  # Unix socket paths are capped at 104 bytes: keep the data dir short.
  defp mkdtemp! do
    {out, 0} = System.cmd("mktemp", ["-d", "/tmp/cgsm.XXXXXX"])
    String.trim(out)
  end

  # clonefile(2), as the agent clones images.
  defp clone!(src, dst) do
    {_, 0} = System.cmd("cp", ["-c", src, dst], stderr_to_stdout: true)
  end
end
