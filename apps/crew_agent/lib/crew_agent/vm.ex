defmodule CrewAgent.VM do
  @moduledoc """
  One job VM on this box: its start sequence (§11.2), its guest API
  session (§13.4), its log stream (§16.2), its deadline and its end.

  The VM itself is the driver's (a systemd unit, a crew-vz helper, or for
  the null driver a local process), never this process's child, so it
  survives the agent (§10.7). This server is restarted for it on agent
  start by adoption (`CrewAgent.VMs.adopt_all/0`).

  **The guest is never trusted** (§13.4): it can only affect its own VM,
  through three signals (`runner_listening`, `job_finished`,
  `job_refused`). Lifecycle comes from the driver.
  """
  use GenServer, restart: :temporary

  require Logger

  alias CrewAgent.{Config, Driver, Net, Outbox, SafeFS}
  alias CrewAgent.VMs.Cleanup
  alias CrewProtocol.{Event, Guest, Text}

  @registry CrewAgent.Registry
  @sessions :crew_guest_sessions

  @poll_ms 1_000
  @flush_ms 250
  @batch_bytes 65_536
  @max_message 240_000
  @max_unacked_bytes 32 * 1024 * 1024
  # Each retained line costs its text and its map; this is the map.
  @line_overhead 64
  @max_unacked_ms 5 * 60_000
  @metrics_ms 5_000
  @steps_ms 1_000
  @control_ms 30_000
  @max_states 20

  # Per-endpoint rates (§13.4): {requests, window_ms}.
  @rates %{steps: {2, 1_000}, log: {8, 1_000}, metrics: {1, 2_000}}

  # -- API ---------------------------------------------------------------------

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: via(vm_id(arg)))

  defp vm_id({:start, cmd, _from}), do: cmd.payload.vm_id
  defp vm_id({:adopt, vm_id}), do: vm_id

  def via(vm_id), do: {:via, Registry, {@registry, {:vm, vm_id}}}

  def whereis(vm_id) do
    case Registry.lookup(@registry, {:vm, vm_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The table the guest API resolves tokens in: `sha256(token) => {vm_id, guest_ip}`."
  def sessions_table, do: @sessions

  def call(vm_id, msg, timeout \\ 5_000) do
    case whereis(vm_id) do
      nil -> {:error, :no_vm}
      pid -> GenServer.call(pid, msg, timeout)
    end
  catch
    :exit, _ -> {:error, :no_vm}
  end

  # -- start (§11.2) ------------------------------------------------------------

  @impl true
  def init({:start, cmd, _from}) do
    config = Config.get()
    p = cmd.payload
    dir = Config.vm_dir(config, p.vm_id)
    Logger.metadata(vm_id: p.vm_id, op_id: cmd.op_id)

    if File.exists?(dir) do
      {:stop, :duplicate}
    else
      case start_vm(config, cmd, dir) do
        {:ok, state} -> {:ok, state, {:continue, :running}}
        {:error, reason} -> {:stop, {:start_failed, reason}}
      end
    end
  end

  def init({:adopt, vm_id}) do
    config = Config.get()
    Logger.metadata(vm_id: vm_id)
    adopt(config, vm_id)
  end

  defp start_vm(config, cmd, dir) do
    p = cmd.payload
    driver = Driver.impl()
    now = now_ms()
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    with :ok <- image_ready(config, p.image),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o750),
         {:ok, lease} <- Net.allocate(p.vm_id) do
      meta = %{
        "vm_id" => p.vm_id,
        "name" => p.name,
        "image" => stringify(p.image),
        "size" => stringify(p.size),
        "deadline" => p.deadline,
        "lease_index" => lease.index,
        "created_at" => now,
        "log_limit_bytes" => p.log_limit_bytes,
        "policy" => stringify(p.policy),
        "labels" => p.labels
      }

      epoch = new_epoch()

      # Without the cache's CA, guests pull straight from the registries.
      ca = ca_pem(config)

      state = %{
        vm_id: p.vm_id,
        dir: dir,
        driver: driver,
        meta: meta,
        lease: lease,
        token_hash: :crypto.hash(:sha256, token),
        payload: %{
          jit_config: p.jit_config,
          ca_pem: ca,
          mirrors: if(ca == "", do: [], else: CrewAgent.Cache.mirrors(config)),
          policy: p.policy,
          size: Map.take(p.size, [:vcpus, :memory_mib, :disk_gib]),
          labels: p.labels,
          # §11.6: only with this box's CREW_CONFORMANCE=1.
          conformance: CrewAgent.Conformance.payload(config, p.vm_id)
        },
        payload_fetched: false,
        started_ms: now
      }

      try do
        SafeFS.write_atomic(Path.join(dir, "vm.json"), Jason.encode!(meta), 0o640)
        clone = clone_rootfs(config, p, dir)
        write_guest_json(state, epoch, 0, 0)

        spec = %{
          vm_id: p.vm_id,
          vcpus: p.size.vcpus,
          memory_mib: p.size.memory_mib,
          disk_gib: p.size.disk_gib,
          limits: p.size.limits,
          image: p.image,
          clone: clone,
          boot_args: boot_args(config, lease, p.vm_id, token),
          net: lease,
          guest_socket: Path.join(dir, "guest.sock"),
          guest_token: token,
          guest_api: guest_api_url(config),
          deadline: p.deadline,
          console_log: Path.join(dir, "console.log"),
          vm_dir: dir
        }

        :ets.insert(@sessions, {state.token_hash, p.vm_id, lease.guest})
        start_guest_socket(config, p.vm_id, spec.guest_socket)

        case driver.start(spec) do
          :ok ->
            {:ok, fresh(state, epoch)}

          {:error, reason} ->
            raise "driver start failed: #{inspect(reason)}"
        end
      rescue
        e ->
          Logger.error("starting VM #{p.vm_id} failed: #{Exception.message(e)}")
          :ets.delete(@sessions, state.token_hash)
          CrewAgent.GuestAPI.stop_socket(p.vm_id)
          abandon_start(driver, p.vm_id, dir)
          {:error, Exception.message(e)}
      end
    else
      {:error, :image_not_ready} -> {:error, :image_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  # A start that failed leaves nothing, unless its cleanup fails too: then
  # its directory stays (vm.json and an exit record, so the inventory has
  # it), with its lease, for the cleanup to be retried.
  defp abandon_start(driver, vm_id, dir) do
    case driver.cleanup(vm_id) do
      :ok ->
        Net.release(vm_id)
        File.rm_rf(dir)

      {:error, why} ->
        exited = %{
          "code" => 0,
          "reason" => "boot_failed",
          "at" => now_ms(),
          "detail" => "start_failed"
        }

        _ = SafeFS.write_atomic(Path.join(dir, "exited.json"), Jason.encode!(exited), 0o640)
        Cleanup.failed(vm_id, if(is_binary(why), do: why, else: inspect(why)))
    end
  end

  # A VM that can't be adopted (a crash between writing vm.json and
  # guest.json, say) ends as any other does: a terminal exit record, so
  # it's never taken for live again, then its cleanup, which releases
  # the lease, the clone and its kernel when it works and is retried
  # when it doesn't, and vm.exited.
  defp abandon_adoption(driver, vm_id, dir) do
    exited = %{
      "code" => 0,
      "reason" => "boot_failed",
      "at" => now_ms(),
      "detail" => "adopt_failed"
    }

    if File.dir?(dir),
      do: _ = SafeFS.write_atomic(Path.join(dir, "exited.json"), Jason.encode!(exited), 0o640)

    cleanup =
      case driver.cleanup(vm_id) do
        :ok ->
          Cleanup.done(vm_id)
          "ok"

        {:error, why} ->
          Cleanup.failed(vm_id, if(is_binary(why), do: why, else: inspect(why)))
          "error"
      end

    emit(
      Event.new("vm.exited", %{
        vm_id: vm_id,
        reason: "boot_failed",
        exit_status: 0,
        uptime_ms: 0,
        cleanup: cleanup,
        detail: "adopt_failed"
      })
    )
  end

  # vz guests reach the API through their own socket (§13.4).
  defp start_guest_socket(%Config{driver: "vz"}, vm_id, path) do
    {:ok, _} = CrewAgent.GuestAPI.start_socket(vm_id, path)
  end

  defp start_guest_socket(_config, _vm_id, _path), do: :ok

  # The image check of §11.2 step 1. The null driver has no images.
  defp image_ready(%Config{driver: "null"}, _image), do: :ok

  defp image_ready(config, image) do
    if CrewAgent.Images.ready?(config, image.id), do: :ok, else: {:error, :image_not_ready}
  end

  defp clone_rootfs(%Config{driver: "null"}, _p, dir) do
    path = Path.join(dir, "rootfs.ext4")
    File.write!(path, "")
    path
  end

  defp clone_rootfs(config, p, dir) do
    CrewAgent.Images.clone(config, p.image.id, Path.join(dir, "rootfs.ext4"), p.size.disk_gib)
  end

  defp ca_pem(config) do
    case CrewAgent.Cache.ca_pem(config) do
      {:ok, pem} -> pem
      _ -> ""
    end
  end

  @doc """
  The kernel command line (§13.3). Firecracker's serial port is an 8250
  UART on arm64 too, so it's ttyS0 there, not §13.3's ttyAMA0 (a PL011,
  which Firecracker doesn't have: the guest found no console).
  """
  def boot_args(config, lease, vm_id, token) do
    console =
      case {config.driver, guest_arch()} do
        {"vz", _} -> "console=hvc0 panic=1 quiet loglevel=4"
        {_, "arm64"} -> "console=ttyS0 panic=1 quiet loglevel=4"
        _ -> "console=ttyS0 reboot=k panic=1 pci=off quiet loglevel=4"
      end

    Enum.join(
      [
        console,
        "root=/dev/vda rw rootfstype=ext4",
        "ip=#{lease.guest}::#{lease.gateway}:#{lease.netmask}::eth0:off",
        "crew.vm=#{vm_id} crew.token=#{token} crew.api=http://#{config.service_ip}:7777"
      ],
      " "
    )
  end

  defp guest_arch do
    if :erlang.system_info(:system_architecture) |> to_string() |> String.contains?("aarch64"),
      do: "arm64",
      else: "x64"
  end

  # The null driver's guest reaches the API on loopback; real guests go
  # through the service address (Firecracker) or their socket (vz).
  defp guest_api_url(config),
    do: "http://#{CrewAgent.GuestAPI.host(config)}:#{CrewAgent.GuestAPI.port()}"

  # -- adoption (§10.7) --------------------------------------------------------

  defp adopt(config, vm_id) do
    dir = Config.vm_dir(config, vm_id)
    driver = Driver.impl()

    with {:ok, meta_json} <- File.read(Path.join(dir, "vm.json")),
         {:ok, meta} <- Jason.decode(meta_json),
         {:ok, guest_json} <- File.read(Path.join(dir, "guest.json")),
         {:ok, guest} <- Jason.decode(guest_json),
         {:ok, lease} <- Net.claim(vm_id, meta["lease_index"]) do
      token_hash = Base.decode64!(guest["token_sha256"])
      epoch = new_epoch()

      state = %{
        vm_id: vm_id,
        dir: dir,
        driver: driver,
        meta: meta,
        lease: lease,
        token_hash: token_hash,
        # The JIT config was only ever in memory: it's gone.
        payload: nil,
        payload_fetched: guest["payload_fetched"] == true,
        started_ms: meta["created_at"]
      }

      # What the VM had reached comes back first, whatever happens next:
      # it decides the exit reason, and it's written back as it was.
      adopted =
        fresh(state, epoch)
        |> Map.merge(%{n: guest["log_n"] || 0, states: MapSet.new(guest["states"] || [])})

      cond do
        not driver.alive?(vm_id) ->
          {:ok, Map.put(adopted, :adopted_dead, true), {:continue, :running}}

        not state.payload_fetched ->
          Logger.warning("adopted VM #{vm_id} never fetched its payload; stopping it")
          driver.stop(vm_id, true)

          {:ok, Map.merge(adopted, %{forced_reason: "boot_failed", exit_detail: "agent_restart"}),
           {:continue, :running}}

        true ->
          :ets.insert(@sessions, {token_hash, vm_id, lease.guest})
          start_guest_socket(config, vm_id, Path.join(dir, "guest.sock"))
          write_guest_json(adopted, epoch, adopted.n, 0)
          {:ok, adopted, {:continue, :running}}
      end
    else
      error ->
        Logger.error("couldn't adopt VM #{vm_id}: #{inspect(error)}")
        abandon_adoption(driver, vm_id, dir)
        :ignore
    end
  end

  defp fresh(state, epoch) do
    Map.merge(state, %{
      epoch: epoch,
      n: 0,
      seq: 0,
      pending: [],
      pending_bytes: 0,
      unacked: [],
      unacked_bytes: 0,
      log_bytes: 0,
      log_truncated: false,
      flush_timer: nil,
      states: MapSet.new(),
      state_count: 0,
      stop_requested: false,
      stop_timer: nil,
      forced_reason: nil,
      exit_detail: nil,
      control_waiter: nil,
      rates: %{},
      steps: nil,
      steps_timer: nil,
      guest_metrics: nil,
      refetch_reported: false,
      # The agent is stopping: new log lines are the next agent's.
      draining: false,
      adopted_dead: false,
      exited: false
    })
  end

  @impl true
  def handle_continue(:running, state) do
    schedule_deadline(state)
    Process.send_after(self(), :poll, @poll_ms)
    Process.send_after(self(), :metrics, @metrics_ms)
    {:noreply, state}
  end

  defp schedule_deadline(%{meta: %{"deadline" => deadline}}) when is_integer(deadline) do
    ms = max(0, deadline * 1000 - now_ms())
    Process.send_after(self(), :deadline, min(ms, 4_294_967_295))
  end

  defp schedule_deadline(_), do: :ok

  # -- the guest API (§13.4) ---------------------------------------------------------

  @impl true
  def handle_call(msg, _from, %{exited: true} = state)
      when msg == :payload or msg == :control or
             (is_tuple(msg) and elem(msg, 0) in [:state, :steps, :log, :metrics, :stop, :kill]),
      do: {:reply, {:error, :no_vm}, state}

  def handle_call(:payload, _from, %{payload_fetched: false, payload: payload} = state)
      when is_map(payload) do
    state = %{state | payload_fetched: true, payload: nil}
    write_guest_json(state, state.epoch, state.n, state.seq)
    emit_state(state, "booted", nil)
    {:reply, {:ok, Guest.payload(payload)}, state}
  end

  def handle_call(:payload, _from, state) do
    state =
      if state.refetch_reported do
        state
      else
        emit_state(state, "booted", "payload_refetch")
        %{state | refetch_reported: true}
      end

    {:reply, {:error, :gone}, state}
  end

  def handle_call({:state, body}, _from, state) do
    with {:ok, s} <- Guest.cast_state(body, life(state)),
         :ok <- state_allowed?(state, s.state) do
      state = %{
        state
        | states: MapSet.put(state.states, s.state),
          state_count: state.state_count + 1
      }

      write_guest_json(state, state.epoch, state.n, state.seq)
      emit_state(state, s.state, s.detail, s.at)
      state = after_guest_state(state, s.state)
      {:reply, {:ok, stop_flag(state)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steps, body}, _from, state) do
    with {:ok, state} <- rate(state, :steps),
         {:ok, steps} <- Guest.cast_steps(body, life(state)) do
      state = %{state | steps: steps}

      state =
        if state.steps_timer,
          do: state,
          else: %{state | steps_timer: Process.send_after(self(), :send_steps, @steps_ms)}

      {:reply, {:ok, stop_flag(state)}, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:log, _body}, _from, %{draining: true} = state),
    do: {:reply, {:error, :draining}, state}

  def handle_call({:log, body}, _from, state) do
    limit = state.meta["log_limit_bytes"] || 104_857_600

    case rate(state, :log) do
      {:ok, state} ->
        cond do
          state.log_truncated ->
            {:reply, {:error, :too_large}, state}

          state.log_bytes + byte_size(body) > limit ->
            state =
              add_lines(state, [
                %{
                  t: now_ms(),
                  step_ref: nil,
                  text:
                    "[Crew: the live log reached its limit of #{limit} bytes; the rest is in GitHub's log]",
                  truncated: false
                }
              ])

            {:reply, {:error, :too_large}, %{state | log_truncated: true}}

          true ->
            {:ok, lines, _skipped} = Guest.parse_ndjson(body, life(state))
            state = %{state | log_bytes: state.log_bytes + byte_size(body)} |> add_lines(lines)
            {:reply, {:ok, stop_flag(state)}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:metrics, body}, _from, state) do
    with {:ok, state} <- rate(state, :metrics),
         {:ok, m} <- Guest.cast_metrics(body, life(state)) do
      {:reply, {:ok, stop_flag(state)}, %{state | guest_metrics: m}}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:control, from, state) do
    cond do
      state.stop_requested ->
        {:reply, {:ok, %{"stop" => true}}, state}

      state.control_waiter ->
        {:reply, {:error, :busy}, state}

      true ->
        timer = Process.send_after(self(), :control_timeout, @control_ms)
        {:noreply, %{state | control_waiter: {from, timer}}}
    end
  end

  # -- commands -----------------------------------------------------------------------

  def handle_call({:stop, force, grace_s}, _from, state) do
    {:reply, :ok, request_stop(state, force, grace_s)}
  end

  # The agent's own kill (an unverified packet filter): forced, with why.
  def handle_call({:kill, detail}, _from, state) do
    {:reply, :ok, request_stop(%{state | exit_detail: state.exit_detail || detail}, true, 0)}
  end

  def handle_call({:log_ack, epoch, seq}, _from, %{epoch: epoch} = state) do
    unacked = Enum.reject(state.unacked, fn {s, _lines, _bytes, _at} -> s <= seq end)
    state = %{state | unacked: unacked, unacked_bytes: sum_bytes(unacked)}

    if state.exited and unacked == [],
      do: {:stop, :normal, :ok, state},
      else: {:reply, :ok, state}
  end

  def handle_call({:log_ack, _epoch, _seq}, _from, state), do: {:reply, :ok, state}

  # Lines from `from_seq` on: those still held are sent again; any before
  # the oldest held are gone (§16.2), and so is a resend for an old epoch.
  def handle_call({:log_resend, epoch, from_seq}, _from, state) do
    if epoch == state.epoch do
      oldest = oldest_seq(state)

      if from_seq < oldest,
        do:
          emit(
            Event.new("vm.log.gone", %{vm_id: state.vm_id, epoch: epoch, up_to_seq: oldest - 1})
          )

      state.unacked
      |> Enum.filter(fn {s, _, _, _} -> s >= from_seq end)
      |> Enum.each(fn {s, lines, _, _} -> emit_log(state, s, lines) end)
    else
      emit(Event.new("vm.log.gone", %{vm_id: state.vm_id, epoch: epoch, up_to_seq: from_seq}))
    end

    {:reply, :ok, state}
  end

  # An agent stop (CrewAgent.VMs.drain_logs/1): the lines held for the
  # next batch go now, no more are taken (the guest keeps them for the
  # next agent), and the reply says whether every batch is acked.
  def handle_call(:drain_logs, _from, state) do
    state = %{flush(state) | draining: true}
    {:reply, state.unacked == [], state}
  end

  # Booted but without its payload yet: the JIT config is only in this
  # process's memory, so an agent restart now loses it (§10.7).
  def handle_call(:starting?, _from, state),
    do: {:reply, not state.exited and not state.payload_fetched, state}

  def handle_call(:info, _from, state) do
    {:reply, %{vm_id: state.vm_id, alive: true, since: state.started_ms, epoch: state.epoch},
     state}
  end

  @impl true
  def handle_cast(:resend_unacked, state) do
    Enum.each(state.unacked, fn {s, lines, _, _} -> emit_log(state, s, lines) end)
    {:noreply, state}
  end

  # -- timers ---------------------------------------------------------------------------

  @impl true
  def handle_info(:logs_expired, %{exited: true} = state), do: {:stop, :normal, state}

  # After the VM's end only its logs are held: nothing else runs.
  def handle_info(msg, %{exited: true} = state)
      when msg in [:poll, :metrics, :deadline, :grace_over],
      do: {:noreply, state}

  def handle_info(:poll, state) do
    if state.adopted_dead or not state.driver.alive?(state.vm_id) do
      finish(state)
    else
      Process.send_after(self(), :poll, @poll_ms)
      {:noreply, state}
    end
  end

  def handle_info(:deadline, state) do
    Logger.warning("VM #{state.vm_id} reached its deadline; killing it")
    state.driver.stop(state.vm_id, true)
    {:noreply, %{state | forced_reason: "killed_deadline"}}
  end

  def handle_info(:grace_over, state) do
    state.driver.stop(state.vm_id, true)
    {:noreply, %{state | forced_reason: state.forced_reason || "killed_stop"}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}

  def handle_info(:send_steps, state) do
    if state.steps do
      emit(
        Event.new("vm.steps", %{vm_id: state.vm_id, steps: Enum.map(state.steps, &stringify/1)})
      )
    end

    {:noreply, %{state | steps_timer: nil}}
  end

  def handle_info(:metrics, state) do
    send_metrics(state)
    Process.send_after(self(), :metrics, @metrics_ms)
    {:noreply, state}
  end

  def handle_info(:control_timeout, %{control_waiter: {from, _}} = state) do
    GenServer.reply(from, :timeout)
    {:noreply, %{state | control_waiter: nil}}
  end

  def handle_info(:control_timeout, state), do: {:noreply, state}

  def handle_info({:kill_disk, _}, state) do
    state.driver.stop(state.vm_id, true)
    {:noreply, %{state | forced_reason: "killed_disk"}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- stopping and ending ---------------------------------------------------------------

  defp request_stop(state, true, _grace_s) do
    state.driver.stop(state.vm_id, true)

    %{state | stop_requested: true, forced_reason: state.forced_reason || "killed_stop"}
    |> wake_control()
  end

  # Graceful (§13.5): the guest hears `stop` on its next response or its
  # control long poll, and powers off; after `grace_s` it's killed.
  defp request_stop(%{stop_requested: true} = state, false, _grace_s), do: state

  defp request_stop(state, false, grace_s) do
    timer = Process.send_after(self(), :grace_over, grace_s * 1000)
    %{state | stop_requested: true, stop_timer: timer} |> wake_control()
  end

  defp wake_control(%{control_waiter: {from, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, %{"stop" => true}})
    %{state | control_waiter: nil}
  end

  defp wake_control(state), do: state

  # `job_finished`: the guest powers off by itself (§13.5); the control
  # plane's finished timeouts cover a guest that doesn't.
  defp after_guest_state(state, _), do: state

  defp finish(state) do
    state = flush(state)
    # Steps still waiting to be coalesced go out before the VM's end.
    if state.steps_timer && state.steps,
      do:
        emit(
          Event.new("vm.steps", %{vm_id: state.vm_id, steps: Enum.map(state.steps, &stringify/1)})
        )

    {code, driver_reason} =
      case state.driver.exit_status(state.vm_id) do
        {:ok, %{code: code, reason: reason}} -> {code, reason}
        _ -> {0, unknown_exit(state.meta, now_ms())}
      end

    reason = exit_reason(state, code, driver_reason)
    cleanup = cleanup(state)
    uptime = max(0, now_ms() - (state.started_ms || now_ms()))

    exited = %{
      "code" => code,
      "reason" => reason,
      "at" => now_ms(),
      "detail" => state.exit_detail
    }

    _ = SafeFS.write_atomic(Path.join(state.dir, "exited.json"), Jason.encode!(exited), 0o640)

    emit(
      Event.new("vm.exited", %{
        vm_id: state.vm_id,
        reason: reason,
        exit_status: code,
        uptime_ms: uptime,
        cleanup: if(cleanup == :ok, do: "ok", else: "error"),
        detail: state.exit_detail
      })
    )

    Logger.info("VM #{state.vm_id} exited (#{reason}, status #{code})")

    # Unacknowledged log batches outlive the VM until they're acked, or
    # for as long as they'd be kept anyway (§16.2).
    if state.unacked == [] do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :logs_expired, @max_unacked_ms)
      {:noreply, %{state | exited: true}}
    end
  end

  @doc """
  How a VM ended when the driver can't say (its exit record out of
  reach): one found gone past its deadline was killed at it, by systemd
  or the helper, which may beat the agent's own timer by a moment.
  """
  def unknown_exit(%{"deadline" => deadline}, now_ms)
      when is_integer(deadline) and now_ms >= deadline * 1000,
      do: "killed_deadline"

  def unknown_exit(_meta, _now_ms), do: nil

  defp exit_reason(%{forced_reason: forced}, _code, _driver) when is_binary(forced), do: forced

  # The driver saw a kill or the deadline (the agent may have been down).
  defp exit_reason(_state, _code, driver) when driver in ["killed_deadline", "killed_stop"],
    do: driver

  defp exit_reason(state, code, _driver) do
    cond do
      not MapSet.member?(state.states, "runner_listening") and not state.payload_fetched ->
        "boot_failed"

      not MapSet.member?(state.states, "runner_listening") ->
        "boot_failed"

      code == 0 ->
        "poweroff"

      true ->
        "crashed"
    end
  end

  # Keep only what the next inventory reports (vm.json and exited.json).
  # A cleanup that fails keeps the lease and the clone, and is retried
  # (CrewAgent.VMs.Cleanup).
  defp cleanup(state) do
    :ets.delete(@sessions, state.token_hash)
    CrewAgent.GuestAPI.stop_socket(state.vm_id)
    for f <- ["guest.sock", "ctl.sock"], do: File.rm(Path.join(state.dir, f))

    case state.driver.cleanup(state.vm_id) do
      :ok ->
        Cleanup.done(state.vm_id)

      {:error, why} ->
        Cleanup.failed(state.vm_id, if(is_binary(why), do: why, else: inspect(why)))
        {:error, why}
    end
  end

  # -- logs (§16.2) ------------------------------------------------------------------------

  defp add_lines(state, []), do: state

  defp add_lines(state, lines) do
    {numbered, n} =
      Enum.map_reduce(lines, state.n, fn line, n ->
        {%{
           "n" => n + 1,
           "t" => line.t,
           "step_ref" => line.step_ref,
           "text" => line.text,
           "truncated" => line.truncated
         }, n + 1}
      end)

    bytes =
      Enum.reduce(numbered, state.pending_bytes, &(byte_size(&1["text"]) + @line_overhead + &2))

    state = %{state | pending: state.pending ++ numbered, pending_bytes: bytes, n: n}

    cond do
      bytes >= @batch_bytes -> flush(state)
      state.flush_timer -> state
      true -> %{state | flush_timer: Process.send_after(self(), :flush, @flush_ms)}
    end
  end

  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)

    {state, _} =
      state.pending
      |> chunk_by_bytes(@max_message)
      |> Enum.reduce({state, nil}, fn lines, {st, _} ->
        seq = st.seq + 1
        emit_log(st, seq, lines)
        bytes = Enum.reduce(lines, 0, &(byte_size(&1["text"]) + @line_overhead + &2))
        unacked = trim_unacked(st.unacked ++ [{seq, lines, bytes, now_ms()}])
        {%{st | seq: seq, unacked: unacked, unacked_bytes: sum_bytes(unacked)}, nil}
      end)

    write_guest_json(state, state.epoch, state.n, state.seq)
    %{state | pending: [], pending_bytes: 0, flush_timer: nil}
  end

  # Unacknowledged batches are kept up to 32 MiB or 5 minutes.
  defp trim_unacked(unacked) do
    cutoff = now_ms() - @max_unacked_ms
    unacked = Enum.reject(unacked, fn {_, _, _, at} -> at < cutoff end)
    drop_until_under(unacked, sum_bytes(unacked))
  end

  defp drop_until_under([_ | rest], bytes) when bytes > @max_unacked_bytes,
    do: drop_until_under(rest, sum_bytes(rest))

  defp drop_until_under(unacked, _bytes), do: unacked

  defp sum_bytes(unacked), do: Enum.reduce(unacked, 0, fn {_, _, b, _}, acc -> acc + b end)
  defp oldest_seq(%{unacked: []} = state), do: state.seq + 1
  defp oldest_seq(%{unacked: [{s, _, _, _} | _]}), do: s

  defp chunk_by_bytes(lines, max) do
    lines
    |> Enum.chunk_while(
      {[], 0},
      fn line, {acc, size} ->
        s = byte_size(line["text"]) * 6 + 128

        if size + s > max and acc != [],
          do: {:cont, Enum.reverse(acc), {[line], s}},
          else: {:cont, {[line | acc], size + s}}
      end,
      fn
        {[], _} -> {:cont, []}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  defp emit_log(state, seq, lines) do
    emit(Event.new("vm.log", %{vm_id: state.vm_id, epoch: state.epoch, seq: seq, lines: lines}))
  end

  # -- helpers ------------------------------------------------------------------------------

  defp state_allowed?(state, new) do
    cond do
      state.state_count >= @max_states -> {:error, :too_many}
      MapSet.member?(state.states, new) -> {:error, :repeated}
      not forward?(state.states, new) -> {:error, :backwards}
      true -> :ok
    end
  end

  @order %{"runner_listening" => 1, "job_started" => 2, "job_finished" => 3, "job_refused" => 3}

  # Forward only; job_refused is allowed after job_started (§13.4).
  defp forward?(states, new) do
    Enum.all?(states, fn s ->
      @order[s] < @order[new] or (s == "job_finished" and new == "job_refused")
    end)
  end

  defp rate(state, key) do
    {limit, window} = Map.fetch!(@rates, key)
    now = now_ms()
    recent = state.rates |> Map.get(key, []) |> Enum.filter(&(&1 > now - window))

    if length(recent) >= limit,
      do: {:error, :rate_limited, state},
      else: {:ok, %{state | rates: Map.put(state.rates, key, [now | recent])}}
  end

  defp stop_flag(%{stop_requested: true}), do: %{"stop" => true}
  defp stop_flag(_), do: nil

  defp emit_state(state, vm_state, detail, at \\ nil) do
    {detail, _} = if detail, do: detail |> Text.scrub() |> Text.cut(1024), else: {nil, false}

    emit(
      Event.new("vm.state", %{
        vm_id: state.vm_id,
        state: vm_state,
        at: at || now_ms(),
        detail: detail
      })
    )
  end

  defp send_metrics(state) do
    host =
      case state.driver.stats(state.vm_id) do
        {:ok, s} -> s
        _ -> %{cpu_pct: 0.0, rss_mib: 0}
      end

    g = state.guest_metrics || %{}

    emit(
      Event.new("vm.metrics", %{
        vm_id: state.vm_id,
        t: now_ms(),
        cpu_pct: Map.get(g, :cpu_pct, 0.0),
        mem_used_mib: Map.get(g, :mem_used_mib, 0),
        mem_total_mib: Map.get(g, :mem_total_mib, 0),
        disk_used_mib: Map.get(g, :disk_used_mib, 0),
        net_rx_bps: 0,
        net_tx_bps: 0,
        host_cpu_pct: min(host.cpu_pct * 1.0, 100_000.0),
        host_rss_mib: host.rss_mib
      })
    )
  end

  defp emit({:ok, event}), do: Outbox.push(event)

  defp emit({:error, errors}) do
    Logger.error("dropped an invalid event: #{inspect(errors) |> String.slice(0, 300)}")
  end

  defp write_guest_json(state, epoch, n, seq) do
    json =
      Jason.encode!(%{
        "token_sha256" => Base.encode64(state.token_hash),
        "lease_index" => state.lease.index,
        "epoch" => epoch,
        "log_n" => n,
        "log_seq" => seq,
        "payload_fetched" => state.payload_fetched,
        "states" => MapSet.to_list(Map.get(state, :states, MapSet.new()))
      })

    SafeFS.write_atomic(Path.join(state.dir, "guest.json"), json, 0o640)
  end

  defp life(state), do: {state.started_ms || 0, now_ms()}

  defp new_epoch, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp now_ms, do: System.os_time(:millisecond)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(v), do: v
end
