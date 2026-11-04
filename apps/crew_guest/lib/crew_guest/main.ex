defmodule CrewGuest.Main do
  @moduledoc """
  The boot sequence and the job's lifecycle (§13.5).

  1. DNS and IPv6, then `resize2fs` in the background.
  2. `GET /v1/payload`, retried every 200 ms for 60 s. If it doesn't come,
     or the agent says it's gone (410) or refuses the token, power off:
     the agent maps an exit before `runner_listening` to `boot_failed`.
  3. The cache CA; then Docker's config, once the resize is done; then
     `READY=1` to systemd, and Docker is started.
  4. The JIT config check: a runner that could update itself is refused,
     with a log line saying why, and the VM powers off.
  5. The run dir: `policy.json` (for the job-started hook), `jit` (0600,
     deleted by the wrapper once read) and `guest.env` (0600: the API URL
     and token, for the hook to report `job_refused`).
  6. The job: steps, pages, metrics, the control poll, and last the runner.

  Steps 1 to 5 run in a task, and so does the final flush, so this process
  can act on a stop at any point.

  **When the runner exits:** `job_finished` with its exit code, then the
  rest of the pages and the worker log are read, everything is flushed
  (10 s at most) and the VM powers off.

  **On `{"stop": true}`** from any response: one SIGTERM to the runner,
  which has until 2 s (`flush_reserve_ms`) before the end of the 10 s
  budget to exit; then the same as above, within the budget. A runner
  still up at its deadline is SIGKILLed with everything it started
  (`CrewGuest.Runner.kill/1`), given up to 0.5 s for its output to close,
  and reported `job_finished` with detail `runner_stop_timeout`. During the
  boot, the boot is dropped and what's held is flushed.

  **On SIGTERM** (`sigterm/1`: systemd is stopping the VM, see
  `CrewGuest.Signals`): the same, within `sigterm_timeout_ms` (11 s, so 9
  s for the runner), and then crew-guest exits instead of powering off. A
  stop already under way keeps its single SIGTERM to the runner, and ends
  by SIGTERM's deadline if that's sooner.

  A failed OS step (DNS, the CA, Docker) is logged and reported as a log
  line, and the boot carries on: the job may not need it.
  """

  use GenServer

  require Logger

  alias CrewGuest.{API, Control, EnvFile, JIT, Metrics, Outbox, Pages, Runner, Steps}

  @resize_timeout 120_000

  # After SIGKILL, how long the runner's output gets to close.
  @kill_wait_ms 500

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Asks for a stop (the agent said `{\"stop\": true}`). Safe to call at any time."
  def request_stop(server \\ __MODULE__), do: GenServer.cast(server, :stop)

  @doc "SIGTERM: stops in order, then exits. Safe to call at any time."
  def sigterm(server \\ __MODULE__), do: GenServer.cast(server, :sigterm)

  # Server

  @impl true
  def init(opts) do
    s = %{
      cfg: Keyword.fetch!(opts, :config),
      system: Keyword.fetch!(opts, :system),
      client: Keyword.fetch!(opts, :client),
      outbox: Keyword.get(opts, :outbox, Outbox),
      # :booting → :running → :stopping → (:killing →) :halting → :halted
      phase: :booting,
      boot: nil,
      job: nil,
      runner: nil,
      drain: nil,
      deadline: nil,
      # What :halted means: :poweroff, or :exit after a SIGTERM.
      ending: :poweroff
    }

    # The job's processes and the tasks are linked: if they fail, this
    # process still flushes and powers off in order.
    Process.flag(:trap_exit, true)
    {:ok, s, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, s), do: {:noreply, %{s | boot: Task.async(fn -> boot(s) end)}}

  @impl true
  def handle_cast(:stop, %{phase: :booting} = s) do
    Logger.info("crew-guest: the agent asked for a stop")
    {:noreply, s |> drop_boot() |> shutdown(deadline(s.cfg.flush_timeout_ms))}
  end

  def handle_cast(:stop, %{phase: :running} = s) do
    Logger.info("crew-guest: the agent asked for a stop")
    {:noreply, stop_runner(s, s.cfg.flush_timeout_ms)}
  end

  def handle_cast(:stop, s), do: {:noreply, s}

  def handle_cast(:sigterm, %{phase: :booting} = s) do
    s = %{s | ending: :exit}
    {:noreply, s |> drop_boot() |> shutdown(deadline(s.cfg.sigterm_timeout_ms))}
  end

  def handle_cast(:sigterm, %{phase: :running} = s),
    do: {:noreply, stop_runner(%{s | ending: :exit}, s.cfg.sigterm_timeout_ms)}

  # The runner has had its SIGTERM; it keeps to SIGTERM's budget too.
  def handle_cast(:sigterm, %{phase: phase} = s) when phase in [:stopping, :killing, :halting] do
    budget = s.cfg.sigterm_timeout_ms
    if phase == :stopping, do: runner_timer(s, budget)
    {:noreply, sooner(%{s | ending: :exit}, deadline(budget))}
  end

  # Powered off already: this SIGTERM is systemd carrying that out.
  def handle_cast(:sigterm, %{phase: :halted, ending: :poweroff} = s) do
    s.system.stop(s.cfg)
    {:noreply, %{s | ending: :exit}}
  end

  def handle_cast(:sigterm, s), do: {:noreply, s}

  @impl true
  def handle_info({ref, result}, %{boot: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    s = %{s | boot: nil}

    case result do
      :ready ->
        {:noreply, start_job(s)}

      :refused ->
        {:noreply, shutdown(s, deadline(s.cfg.flush_timeout_ms))}

      {:no_payload, reason} ->
        Logger.error("crew-guest: no payload (#{inspect(reason)}); powering off")
        {:noreply, halt(s)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{boot: %Task{ref: ref}} = s) do
    report(s, "crew-guest: the boot failed (#{inspect(reason)})")
    {:noreply, shutdown(%{s | boot: nil}, deadline(s.cfg.flush_timeout_ms))}
  end

  def handle_info({ref, result}, %{drain: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])
    if result != :ok, do: undelivered()
    {:noreply, halt(%{s | drain: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{drain: %Task{ref: ref}} = s) do
    Logger.warning("crew-guest: the flush failed (#{inspect(reason)})")
    {:noreply, halt(%{s | drain: nil})}
  end

  # The flush is out of time, even if it hasn't noticed.
  def handle_info(:deadline, %{phase: :halting} = s) do
    Task.shutdown(s.drain, :brutal_kill)
    undelivered()
    {:noreply, halt(%{s | drain: nil})}
  end

  def handle_info({:runner_exited, status}, %{phase: phase} = s)
      when phase in [:running, :stopping] do
    Outbox.state(s.outbox, "job_finished", "exit_code=#{status}")
    {:noreply, shutdown(s, s.deadline || deadline(s.cfg.flush_timeout_ms))}
  end

  # Its deadline: SIGKILL to the runner and all it started, so nothing
  # writes past the last snapshot, and a moment for its output to close.
  def handle_info(:runner_stop_timeout, %{phase: :stopping} = s) do
    Logger.warning("crew-guest: the runner didn't exit after SIGTERM")

    try do
      Runner.kill(s.runner)
    catch
      :exit, _reason -> :ok
    end

    wait = min(@kill_wait_ms, max(s.deadline - now(), 0))
    Process.send_after(self(), :runner_kill_timeout, wait)
    {:noreply, %{s | phase: :killing}}
  end

  def handle_info({:runner_exited, _status}, %{phase: :killing} = s), do: {:noreply, killed(s)}

  def handle_info(:runner_kill_timeout, %{phase: :killing} = s) do
    Logger.warning("crew-guest: the runner's output is still open after SIGKILL")
    {:noreply, killed(s)}
  end

  # The runner's process went without reporting an exit.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runner: pid, phase: phase} = s)
      when phase in [:running, :stopping, :killing] and reason != :normal do
    report(s, "crew-guest: lost track of the runner (#{inspect(reason)})")
    {:noreply, shutdown(s, s.deadline || deadline(s.cfg.flush_timeout_ms))}
  end

  # The job's supervisor gave up (a part kept crashing).
  def handle_info({:EXIT, job, reason}, %{job: job, phase: phase} = s)
      when phase in [:running, :stopping, :killing] do
    report(s, "crew-guest: the job's processes failed (#{inspect(reason)})")
    {:noreply, shutdown(s, s.deadline || deadline(s.cfg.flush_timeout_ms))}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # Boot (in its task)

  defp boot(s) do
    %{cfg: cfg, system: sys} = s
    step(s, "setting up the network", fn -> sys.setup_network(cfg) end)
    resize = Task.async(fn -> sys.resize_root(cfg) end)

    case fetch_payload(s) do
      {:ok, payload} -> setup(s, payload, resize)
      {:error, reason} -> {:no_payload, reason}
    end
  end

  defp setup(s, payload, resize) do
    %{cfg: cfg, system: sys} = s
    pem = present(payload["ca_pem"])

    if pem, do: step(s, "installing the cache CA", fn -> sys.install_ca(cfg, pem) end)
    await_resize(s, resize)
    step(s, "configuring Docker", fn -> sys.configure_docker(cfg, pem) end)
    step(s, "notifying systemd", fn -> sys.notify_ready(cfg) end)
    step(s, "starting Docker", fn -> sys.start_docker(cfg) end)

    with :ok <- check_jit(s, payload["jit_config"]),
         :ok <- prepare_runner(s, payload) do
      :ready
    else
      :error -> :refused
    end
  end

  defp fetch_payload(s) do
    deadline = deadline(s.cfg.payload_timeout_ms)
    fetch_payload(s, deadline)
  end

  defp fetch_payload(s, deadline) do
    case API.get_payload(s.client, receive_timeout: 5_000) do
      {:ok, %{"jit_config" => jit} = payload} when is_binary(jit) ->
        {:ok, payload}

      {:ok, _payload} ->
        {:error, :bad_payload}

      # Gone (fetched already), or a token the agent doesn't know: neither
      # gets better with retrying.
      {:error, {:status, status}} when status in 400..499 and status not in [408, 429] ->
        {:error, {:status, status}}

      {:error, reason} ->
        if now() + s.cfg.payload_retry_ms < deadline do
          Process.sleep(s.cfg.payload_retry_ms)
          fetch_payload(s, deadline)
        else
          {:error, {:timeout, reason}}
        end
    end
  end

  defp await_resize(s, task) do
    case Task.yield(task, @resize_timeout) || Task.shutdown(task) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        report(s, "crew-guest: resizing the disk failed: #{inspect(reason)}")

      {:exit, reason} ->
        report(s, "crew-guest: resizing the disk failed: #{inspect(reason)}")

      nil ->
        report(s, "crew-guest: resizing the disk didn't finish; carrying on")
    end
  end

  defp check_jit(s, jit) do
    case JIT.check(jit) do
      :ok ->
        :ok

      {:error, reason} ->
        report(s, "crew-guest: refusing to start the runner: #{reason}")
        :error
    end
  end

  defp prepare_runner(s, payload) do
    cfg = s.cfg

    guest_env =
      EnvFile.shell([
        {"CREW_VM", cfg.vm_id},
        {"CREW_API", cfg.api_url},
        {"CREW_TOKEN", cfg.token}
      ])

    files = [
      {"policy.json", Jason.encode!(payload["policy"] || %{}), :public},
      {"jit", payload["jit_config"], :private},
      {"guest.env", guest_env, :private}
    ]

    case s.system.prepare_runner(cfg, files) do
      :ok ->
        :ok

      {:error, reason} ->
        report(s, "crew-guest: couldn't prepare the runner: #{inspect(reason)}")
        :error
    end
  end

  defp drop_boot(%{boot: nil} = s), do: s

  defp drop_boot(s) do
    Task.shutdown(s.boot, :brutal_kill)
    %{s | boot: nil}
  end

  # The job

  defp start_job(s) do
    %{cfg: cfg, outbox: outbox} = s
    diag = Path.join(cfg.runner_dir, "_diag")
    main = self()

    children = [
      {Steps,
       name: Steps,
       diag_dir: diag,
       on_steps: &Outbox.steps(outbox, &1),
       on_job_started: fn -> Outbox.state(outbox, "job_started") end},
      {Pages,
       name: Pages,
       dir: Path.join(diag, "pages"),
       on_lines: &Outbox.log(outbox, &1),
       on_activity: &Steps.activity(Steps, &1, &2, &3)},
      {Metrics, name: Metrics, client: s.client, interval_ms: cfg.metrics_interval_ms},
      {Control, client: s.client},
      {Runner,
       name: Runner,
       config: cfg,
       system: s.system,
       jit_file: Path.join(cfg.run_dir, "jit"),
       on_state: &Outbox.state(outbox, &1),
       on_exit: &send(main, {:runner_exited, &1})}
    ]

    # A part that crashes is restarted (the runner isn't: it's temporary).
    case Supervisor.start_link(children,
           strategy: :one_for_one,
           max_restarts: 10,
           max_seconds: 60
         ) do
      {:ok, job} ->
        runner = Process.whereis(Runner)
        Process.monitor(runner)
        %{s | job: job, runner: runner, phase: :running}

      {:error, reason} ->
        report(s, "crew-guest: couldn't start the runner: #{inspect(reason)}")
        shutdown(s, deadline(s.cfg.flush_timeout_ms))
    end
  end

  # SIGTERM to the runner (once: Runner.stop/1 sees to that), which gets
  # all of the budget but the flush's reserve to exit.
  defp stop_runner(s, budget) do
    try do
      Runner.stop(s.runner)
    catch
      # It has just exited: its exit is already on its way here.
      :exit, _reason -> :ok
    end

    runner_timer(s, budget)
    %{s | phase: :stopping, deadline: deadline(budget)}
  end

  defp runner_timer(s, budget),
    do: Process.send_after(self(), :runner_stop_timeout, max(budget - s.cfg.flush_reserve_ms, 0))

  defp killed(s) do
    Outbox.state(s.outbox, "job_finished", "runner_stop_timeout")
    shutdown(s, s.deadline)
  end

  # Ending

  # The flush runs apart, so a SIGTERM can still cut it short.
  defp shutdown(s, deadline) do
    outbox = s.outbox
    drain = Task.async(fn -> drain(outbox, deadline) end)
    arm(deadline)
    %{s | phase: :halting, drain: drain, deadline: deadline}
  end

  # In its task: pages and steps that are left go into the outbox before
  # the flush.
  defp drain(outbox, deadline) do
    finish(Pages, deadline)
    finish(Steps, deadline)
    Outbox.flush(outbox, max(deadline - now(), 0))
  end

  defp finish(module, deadline) do
    if Process.whereis(module), do: module.finish(module, max(deadline - now(), 100))
  catch
    :exit, reason ->
      Logger.warning("crew-guest: #{inspect(module)} didn't finish: #{inspect(reason)}")
  end

  defp sooner(%{deadline: current} = s, deadline) when deadline < current do
    if s.phase == :halting, do: arm(deadline)
    %{s | deadline: deadline}
  end

  defp sooner(s, _deadline), do: s

  defp arm(deadline), do: Process.send_after(self(), :deadline, max(deadline - now(), 0))

  defp undelivered, do: Logger.warning("crew-guest: ending with reports undelivered")

  defp halt(%{ending: :exit} = s) do
    Logger.info("crew-guest: stopping")
    s.system.stop(s.cfg)
    %{s | phase: :halted}
  end

  defp halt(s) do
    Logger.info("crew-guest: powering off")
    s.system.poweroff(s.cfg)
    %{s | phase: :halted}
  end

  # Helpers

  defp step(s, what, fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> report(s, "crew-guest: #{what} failed: #{inspect(reason)}")
    end
  end

  # Logged here and sent as a log line, so the job page shows it too.
  defp report(s, text) do
    Logger.warning(text)
    Outbox.log(s.outbox, [%{t: System.system_time(:millisecond), step_ref: nil, text: text}])
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp deadline(ms), do: now() + ms
  defp now, do: System.monotonic_time(:millisecond)
end
