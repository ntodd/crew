defmodule Crew.VMs.Server do
  @moduledoc """
  Owns one VM that isn't destroyed (§9.3): its state machine
  (`Crew.VMs.Machine`) and timers, its JIT config, and the effects of
  each transition. Each transition is written in one transaction with
  its event.

  The JIT config is held here, in memory only, until the VM leaves
  `requested` (§6.3).

  On control plane boot a server starts for every VM that isn't
  destroyed, and its timers are recomputed from the stored timestamps.
  A VM still in `requested` gets its runner deleted and becomes failed
  (`cp_restart`), or busy when the delete answers 422: `vm.start` is
  never resent (§8.6).
  """
  use GenServer, restart: :transient

  import Ecto.Query

  require Logger

  alias Crew.{Activity, Boxes, Jobs, Operations, Repo, Repos, Scheduler, Sizes}
  alias Crew.GitHub.Client
  alias Crew.Scheduler.ClassState
  alias Crew.VMs.{Machine, VM, VMEvent}

  @registry Crew.Registry

  # §8.6's timers. Tests shorten them through `:vm_timers_ms`.
  @timers %{
    jit: 15_000,
    ack: 30_000,
    boot: 60_000,
    runner: 60_000,
    finished_grace: 30_000,
    finished_force: 120_000,
    check: 60_000,
    first_check: 5_000,
    delete_retry: 30_000,
    jit_retry: 3_000,
    deadline_retry: 60_000
  }

  # Gone before GitHub named its job, and holding its share until its
  # runner is (Crew.VMs.Machine).
  defguardp unlinked?(vm)
            when is_map_key(vm, :fail_reason) and
                   :erlang.map_get(:fail_reason, vm) in ["unlinked", "unlinked_cleanup"]

  defp ms(name),
    do: Map.get(Application.get_env(:crew, :vm_timers_ms, %{}), name, Map.fetch!(@timers, name))

  @backoff_after 5
  @stall_minutes [10, 20, 40, 60]

  def start_link({mode, vm_id}),
    do: GenServer.start_link(__MODULE__, {mode, vm_id}, name: via(vm_id))

  def child_spec({mode, vm_id}),
    do: %{
      id: {__MODULE__, vm_id},
      start: {__MODULE__, :start_link, [{mode, vm_id}]},
      restart: :transient
    }

  def via(vm_id), do: {:via, Registry, {@registry, {:vm_server, vm_id}}}

  def whereis(vm_id) do
    case Registry.lookup(@registry, {:vm_server, vm_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Delivers a lifecycle event to the VM's server."
  def event(vm_id, event) do
    case whereis(vm_id) do
      nil -> {:error, :no_server}
      pid -> GenServer.cast(pid, {:event, event})
    end
  end

  # -- start ------------------------------------------------------------------------

  @impl true
  def init({mode, vm_id}) do
    # A shutdown waits for the current transition to be written.
    Process.flag(:trap_exit, true)

    case Repo.get(VM, vm_id) do
      nil ->
        :ignore

      %VM{state: "destroyed"} ->
        :ignore

      vm ->
        {:ok, %{vm: vm, jit_config: nil, timers: %{}, delete_attempt: nil, reap_why: nil},
         {:continue, start_mode(mode, vm)}}
    end
  end

  # A supervisor restart reuses the child's arguments, so a server that
  # crashed after its placement started comes back as at boot: from the
  # database, and never with a second JIT config.
  defp start_mode(:new, vm) do
    if Repo.exists?(from e in VMEvent, where: e.vm_id == ^vm.id), do: :boot, else: :new
  end

  defp start_mode(mode, _vm), do: mode

  @impl true
  def handle_continue(:new, state) do
    state = record(state, "provision", %{})
    request_jit(state)
    {:noreply, arm_registration_timer(state, :jit, ms(:jit))}
  end

  def handle_continue(:boot, %{vm: %VM{state: "requested", runner_id: nil}} = state) do
    # The control plane restarted mid-placement: start over with a fresh
    # VM and JIT config, never a resent vm.start.
    {:noreply, apply_transition(state, {:runner_deleted, :gone, "cp_restart"})}
  end

  def handle_continue(:boot, %{vm: %VM{state: "requested"}} = state) do
    # vm.start may have reached the agent: the runner is deleted first,
    # and a 422 means it took a job, so the VM is busy (§8.6).
    {:noreply, effect(state, {:delete_runner_then, "cp_restart"}, :boot)}
  end

  # Asked again, within the give-up it had: counted from when it finished,
  # so restarts can't hold its share for ever.
  def handle_continue(:boot, %{vm: %VM{state: "finished"} = vm} = state) when unlinked?(vm) do
    # One whose cleanup is outstanding asks the box again, as any
    # finished VM does (rearm/1).
    state = if vm.fail_reason == "unlinked_cleanup", do: rearm(state), else: state
    state = effect(state, {:delete_runner_then, "unlinked"}, :boot)
    held = DateTime.diff(DateTime.utc_now(), vm.finished_at || DateTime.utc_now(), :millisecond)

    case state.delete_attempt do
      %{since: since} = attempt ->
        {:noreply, %{state | delete_attempt: %{attempt | since: since - max(held, 0)}}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_continue(:boot, state), do: {:noreply, rearm(state)}

  # Timers recomputed from the stored timestamps.
  defp rearm(%{vm: vm} = state) do
    now = DateTime.utc_now()

    case vm.state do
      "starting" ->
        arm(state, :state, remaining(vm.started_at, ms(:boot), now), {:timeout, "boot_timeout"})

      "booted" ->
        arm(
          state,
          :state,
          remaining(vm.booted_at, ms(:runner), now),
          {:timeout, "runner_timeout"}
        )

      "busy" ->
        arm_deadline(state)

      "finished" ->
        arm_finished(state, vm.finished_at)

      "failed" ->
        arm(state, :check, ms(:first_check), :check)

      _ ->
        state
    end
  end

  defp remaining(nil, ms, _now), do: ms
  defp remaining(since, ms, now), do: max(0, ms - DateTime.diff(now, since, :millisecond))
  defp remaining_until(nil, _now), do: 4_000_000_000

  defp remaining_until(at, now),
    do: min(max(0, DateTime.diff(at, now, :millisecond)), 4_000_000_000)

  # -- JIT and vm.start (§6.3, §8.6) -------------------------------------------------

  defp arm_registration_timer(state, name, delay) do
    state = cancel_registration_timer(state, name)
    ref = :erlang.start_timer(delay, self(), name)
    put_in(state.timers[name], ref)
  end

  defp cancel_registration_timer(state, name) do
    {ref, timers} = Map.pop(state.timers, name)
    if ref, do: Process.cancel_timer(ref)
    %{state | timers: timers}
  end

  defp request_jit(%{vm: vm}) do
    server = self()
    repo = vm.repo_id |> Repos.get!() |> Repos.with_installation()
    callers = [self() | Process.get(:"$callers", [])]

    Task.start(fn ->
      Process.put(:"$callers", callers)

      result =
        Client.generate_jit_config(
          repo.installation.github_id,
          repo.full_name,
          vm.name,
          vm.class_key
        )

      send(server, {:jit, result})
    end)
  end

  @impl true
  def handle_info(
        {:jit, {:ok, %{runner_id: runner_id, jit_config: jit}}},
        %{vm: %VM{state: "requested"}} = state
      ) do
    vm = state.vm |> Ecto.Changeset.change(runner_id: runner_id) |> Repo.update!()
    state = %{state | vm: vm, jit_config: jit} |> cancel_registration_timer(:jit)
    {:noreply, send_start(state)}
  end

  def handle_info({:jit, {:ok, %{runner_id: runner_id}}}, state) do
    # Too late: the VM moved on. The runner it would have had goes.
    delete_runner_async(state.vm, runner_id)
    {:noreply, state}
  end

  def handle_info(
        {:jit, {:error, {:write_limited, until_ms}}},
        %{vm: %VM{state: "requested", runner_id: nil}} = state
      ) do
    delay = max(1, until_ms - System.os_time(:millisecond))

    state =
      state
      |> cancel_registration_timer(:jit)
      |> record("jit_budget_wait", %{"until_ms" => until_ms})

    {:noreply, arm_registration_timer(state, :jit_budget, delay)}
  end

  def handle_info({:jit, {:error, reason}}, %{vm: %VM{state: "requested"}} = state) do
    Logger.warning("JIT config for #{state.vm.name} failed: #{inspect(reason)}; retrying")
    Process.send_after(self(), :retry_jit, ms(:jit_retry))
    {:noreply, record(state, "jit_error", %{"error" => inspect(reason) |> String.slice(0, 300)})}
  end

  def handle_info({:timeout, ref, :jit_budget}, %{timers: %{jit_budget: ref}} = state) do
    state = cancel_registration_timer(state, :jit_budget)

    if state.vm.state == "requested" and is_nil(state.vm.runner_id) do
      request_jit(state)
      {:noreply, arm_registration_timer(state, :jit, ms(:jit))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:timeout, ref, :jit}, %{timers: %{jit: ref}} = state) do
    {:noreply,
     state |> cancel_registration_timer(:jit) |> apply_transition({:timeout, "jit_timeout"})}
  end

  def handle_info({:jit, _}, state), do: {:noreply, state}

  def handle_info(:retry_jit, %{vm: %VM{state: "requested", runner_id: nil}} = state) do
    request_jit(state)
    {:noreply, state}
  end

  def handle_info(:retry_jit, state), do: {:noreply, state}

  # A timer's message carries its ref. One that isn't armed any more
  # fired just before it was disarmed or re-armed: the state it timed is
  # over, and its message is dropped.
  def handle_info({:timeout, ref, {name, event}}, state) when is_reference(ref) do
    case Map.pop(state.timers, name) do
      {^ref, timers} -> on_timer(name, event, %{state | timers: timers})
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:runner_delete_result, ref, result},
        %{delete_attempt: %{ref: ref, reason: reason} = attempt} = state
      ) do
    case result do
      # The runner of a VM that's gone is on a job somewhere: it's still
      # registered, so it's asked again until it isn't.
      {:ok, :busy} when reason == "unlinked" ->
        retry_delete(state, attempt, :busy)

      {:ok, outcome} ->
        {:noreply,
         %{state | delete_attempt: nil} |> apply_transition({:runner_deleted, outcome, reason})}

      {:error, _} when attempt.origin != state.vm.state and reason != "lost" ->
        {:noreply, %{state | delete_attempt: nil}}

      {:error, error} ->
        retry_delete(state, attempt, error)
    end
  end

  def handle_info({:retry_delete, ref}, %{delete_attempt: %{ref: ref}} = state) do
    if state.delete_attempt.origin == state.vm.state or state.delete_attempt.reason == "lost" do
      delete_runner_then(state, ref)
      {:noreply, state}
    else
      {:noreply, %{state | delete_attempt: nil}}
    end
  end

  def handle_info({:retry_delete, _ref}, state), do: {:noreply, state}
  def handle_info({:runner_delete_result, _ref, _result}, state), do: {:noreply, state}

  def handle_info({:op_result, %{status: status} = op}, state) do
    result = if status == "succeeded", do: :ok, else: :error
    {:noreply, apply_transition(state, {:start_result, result}, start_error_code: op.error_code)}
  end

  def handle_info(:stop_self, state), do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # A failed or finished VM that hasn't exited: a forced stop while it's
  # alive, and the box's inventory, which destroys it once it isn't
  # listed (§8.6, §10.6). A VM the agent never started gets no vm.exited.
  defp on_timer(:check, _event, state) do
    state =
      if state.vm.state == "failed" and state.vm.alive,
        do: apply_transition(state, :failed_alive_tick),
        else: state

    Operations.dispatch(state.vm.box_id, "box.inventory", %{})

    if state.vm.state in ["failed", "finished"],
      do: {:noreply, arm(state, :check, ms(:check), :check)},
      else: {:noreply, state}
  end

  # The deadline: a forced stop, and then every minute a forced stop and
  # the box's inventory until the VM is gone (the agent enforces it too,
  # §10.7).
  defp on_timer(:deadline, _event, state) do
    state = apply_transition(state, :deadline)

    if state.vm.state == "busy", do: Operations.dispatch(state.vm.box_id, "box.inventory", %{})
    {:noreply, state}
  end

  defp on_timer(_name, event, state), do: {:noreply, apply_transition(state, event)}

  defp send_start(%{vm: vm, jit_config: jit} = state) do
    repo = Repos.get!(vm.repo_id)
    image = vm.image_id && Crew.Images.get(vm.image_id)
    size = Sizes.get!(vm.size_id)

    payload = %{
      "vm_id" => vm.id,
      "name" => vm.name,
      "size" => %{
        "vcpus" => vm.vcpus,
        "memory_mib" => vm.memory_mib,
        "disk_gib" => vm.disk_gib,
        "limits" => stringify(Crew.Sizes.Size.limits(size))
      },
      "image" => %{
        "id" => vm.image_id,
        "version" => image && image.version,
        "arch" => image && image.arch,
        "manifest_sha256" => image && image.manifest_sha256
      },
      "jit_config" => jit,
      "labels" => vm.class_key,
      "deadline" => DateTime.to_unix(vm.deadline),
      "log_limit_bytes" => Application.get_env(:crew, :log_limit_bytes, 104_857_600),
      "policy" => %{"fork_prs" => repo.fork_prs, "repo_full_name" => repo.full_name}
    }

    # Older agents reject unknown fields. Only require an upgraded agent
    # when the deployment explicitly requires a strict guest.
    payload =
      if Crew.Caches.config().strict_registry_cache,
        do: Map.put(payload, "strict_registry_cache", true),
        else: payload

    case Operations.dispatch(vm.box_id, "vm.start", payload, vm_id: vm.id) do
      {:ok, op} ->
        Phoenix.PubSub.subscribe(Crew.PubSub, "op:#{op.id}")
        # A result that landed before the subscription isn't missed.
        with %{status: s} = done when s in ["succeeded", "failed"] <- Operations.get(op.id),
             do: send(self(), {:op_result, done})

        vm = vm |> Ecto.Changeset.change(start_op_id: op.id) |> Repo.update!()
        state = %{state | vm: vm} |> record("start_sent", %{"op_id" => op.id})
        arm(state, :ack, ms(:ack), {:timeout, "agent_timeout"})

      {:error, :offline} ->
        # Not sent: the ack timeout fails it, and the plan places another.
        arm(state, :ack, ms(:ack), {:timeout, "agent_timeout"})

      {:error, reason} ->
        Logger.error("vm.start for #{vm.name} was refused before sending: #{inspect(reason)}")
        apply_transition(state, {:start_result, :error})
    end
  end

  # -- events -------------------------------------------------------------------------

  @impl true
  def handle_cast({:event, {:reap, _}}, %{delete_attempt: attempt} = state)
      when not is_nil(attempt), do: {:noreply, state}

  def handle_cast({:event, {:reap, why} = event}, state),
    do: {:noreply, apply_transition(%{state | reap_why: why}, event)}

  def handle_cast({:event, event}, state), do: {:noreply, apply_transition(state, event)}

  defp apply_transition(state, event, opts \\ []) do
    machine = %{
      state: state.vm.state,
      fail_reason: state.vm.fail_reason,
      job_id: state.vm.job_id,
      alive: state.vm.alive
    }

    case Machine.transition(machine, event) do
      :ignored ->
        record(state, "ignored", %{"event" => describe(event)})

      {:ok, ^machine, [{:delete_runner_then, _} = delete]} ->
        effect(state, delete, event)

      {:ok, next, effects} ->
        next = override_reason(next, opts)

        # A VM waiting on its runner's delete keeps the attempt while
        # GitHub names its job.
        state =
          if next.state in ~w(busy finished failed destroyed) and not unlinked?(next),
            do: %{state | delete_attempt: nil},
            else: state

        state = persist(state, machine, next, event)
        state = Enum.reduce(effects, state, &effect(&2, &1, event))
        state = accounting(state, machine, next)
        state |> after_state() |> carry_on(machine.state, next.state, event)
    end
  end

  # A busy VM that exited, or that the inventory no longer lists, is
  # finished; a VM that did either before its job is failed. The same
  # event then destroys it (§8.6's finished and failed columns), so a VM
  # that's gone doesn't hold its allocation through the timers. A cleanup
  # that failed keeps it.
  @pre_job ~w(requested starting booted idle)
  defp carry_on(%{vm: vm} = state, "busy", "finished", _event) when unlinked?(vm), do: state

  defp carry_on(state, from, to, event)
       when ((from == "busy" and to == "finished") or (from in @pre_job and to == "failed")) and
              (event == :inventory_missing or elem(event, 0) == :exited),
       do: apply_transition(state, event)

  defp carry_on(state, _from, _to, _event), do: state

  defp override_reason(%{state: "failed"} = next, opts) do
    if opts[:start_error_code] == "image_not_ready",
      do: %{next | fail_reason: "image_not_ready"},
      else: next
  end

  defp override_reason(next, _opts), do: next

  defp persist(state, before, next, event) do
    now = DateTime.utc_now()

    changes =
      %{state: next.state, fail_reason: next.fail_reason, job_id: next.job_id, alive: next.alive}
      |> Map.merge(timestamps(before.state, next.state, now))
      |> Map.merge(alive_for(event, next))

    vm =
      Repo.transact(fn ->
        vm = state.vm |> Ecto.Changeset.change(changes) |> Repo.update!()

        Repo.insert!(%VMEvent{
          vm_id: vm.id,
          kind: describe(event),
          payload: %{"from" => before.state, "to" => next.state},
          at: now
        })

        {:ok, vm}
      end)
      |> elem(1)

    if before.state != next.state, do: broadcast(vm)
    state = %{state | vm: vm}
    if next.state != "requested", do: %{state | jit_config: nil}, else: state
  end

  defp alive_for({:start_result, :ok}, _next), do: %{alive: true}
  defp alive_for(:booted, _next), do: %{alive: true}
  defp alive_for(_, _next), do: %{}

  defp timestamps(same, same, _now), do: %{}

  defp timestamps(_from, to, now) do
    case to do
      "starting" -> %{started_at: now}
      "booted" -> %{booted_at: now}
      "idle" -> %{idle_at: now}
      "busy" -> %{busy_at: now}
      "finished" -> %{finished_at: now}
      "failed" -> %{failed_at: now}
      "destroyed" -> %{destroyed_at: now}
      _ -> %{}
    end
  end

  defp after_state(%{vm: %VM{state: "destroyed"} = vm} = state) do
    Scheduler.poke()
    # Every sample is in: the job's resource summary is final (§16.5).
    if vm.job_id, do: Jobs.summarize_final(vm.job_id)
    # A reboot waiting for the box's last VM (§12.1).
    Crew.Boxes.Reboots.advance(vm.box_id)
    send(self(), :stop_self)
    disarm_all(state)
  end

  defp after_state(%{vm: vm} = state) do
    Scheduler.poke()

    state =
      case vm.state do
        "starting" ->
          state |> disarm(:ack) |> arm_once(:state, ms(:boot), {:timeout, "boot_timeout"})

        "booted" ->
          state |> disarm(:ack) |> arm(:state, ms(:runner), {:timeout, "runner_timeout"})

        "idle" ->
          state |> disarm(:ack) |> disarm(:state)

        "busy" ->
          # The boot or runner timer gives way to the deadline: an
          # in_progress can come before runner_listening.
          state
          |> disarm(:ack)
          |> disarm(:check)
          |> disarm(:state)
          |> then(&if(Map.has_key?(&1.timers, :deadline), do: &1, else: arm_deadline(&1)))

        "failed" ->
          state
          |> disarm(:ack)
          |> disarm(:state)
          |> arm_once(:check, if(vm.alive, do: ms(:check), else: ms(:first_check)), :check)

        _ ->
          state
      end

    state
  end

  defp retry_delete(state, %{ref: ref, reason: reason, since: since}, why) do
    limit = (Application.get_env(:crew, :idle_max_s, 600) + 300) * 1000

    if System.monotonic_time(:millisecond) - since > limit do
      # Past CREW_IDLE_MAX + 300 s: stop anyway, and leave the
      # runner to garbage collection (§6.3).
      Logger.warning("giving up deleting #{state.vm.name}'s runner: #{inspect(why)}")

      {:noreply,
       %{state | delete_attempt: nil} |> apply_transition({:runner_deleted, :gone, reason})}
    else
      Process.send_after(self(), {:retry_delete, ref}, ms(:delete_retry))
      {:noreply, state}
    end
  end

  # -- effects --------------------------------------------------------------------------

  defp effect(state, :record_start_op, _event), do: state

  defp effect(state, :delete_runner, _event) do
    if state.vm.runner_id, do: delete_runner_async(state.vm, state.vm.runner_id)
    state
  end

  # The delete's answer settles a requested VM, so its ack timeout can't
  # start a second delete meanwhile. Without a runner there's nothing to
  # delete: the answer is :gone, now. Sent to itself instead, it could
  # land after a JIT config already in the mailbox had registered a
  # runner and sent vm.start.
  defp effect(%{delete_attempt: attempt} = state, {:delete_runner_then, _}, _event)
       when not is_nil(attempt), do: state

  defp effect(state, {:delete_runner_then, reason}, _event) do
    if state.vm.runner_id do
      attempt = %{
        ref: make_ref(),
        since: System.monotonic_time(:millisecond),
        reason: reason,
        origin: state.vm.state
      }

      delete_runner_then(state, attempt.ref)
      disarm(%{state | delete_attempt: attempt}, :ack)
    else
      apply_transition(state, {:runner_deleted, :gone, reason})
    end
  end

  defp effect(state, {:stop, force}, event) do
    reason = stop_reason(state.vm, event)

    case Operations.dispatch(
           state.vm.box_id,
           "vm.stop",
           %{"vm_id" => state.vm.id, "reason" => reason, "force" => force, "grace_s" => 30},
           vm_id: state.vm.id
         ) do
      {:ok, _} ->
        %{
          state
          | vm:
              state.vm
              |> Ecto.Changeset.change(stop_sent_at: DateTime.utc_now())
              |> Repo.update!()
        }

      _ ->
        state
    end
  end

  defp effect(state, :fetch_job, _event) do
    # 422: the runner took a job. Link it if the job is already known;
    # the reconciler's busy-VM check finds it otherwise (§8.8).
    case Jobs.find_by_runner_name(state.vm.name) do
      %{id: job_id} -> apply_transition(state, {:job_started, job_id})
      nil -> state
    end
  end

  defp effect(state, {:link_job, job_id}, _event) do
    Jobs.link_vm(job_id, state.vm)
    Boxes.ran_repo(state.vm.box_id, state.vm.repo_id)
    state
  end

  defp effect(state, :cancel_force_stop, _event), do: disarm(state, :check)
  defp effect(state, :arm_finished, _event), do: arm_finished(state, DateTime.utc_now())
  defp effect(state, :success, _event), do: state

  defp effect(state, :cleanup_failed, _event) do
    Activity.record("notice", "Cleaning up VM #{state.vm.name} failed on its box",
      box_id: state.vm.box_id
    )

    state
  end

  defp stop_reason(%VM{fail_reason: "reaped"}, _event), do: "reaped"
  defp stop_reason(_vm, :deadline), do: "deadline"
  defp stop_reason(_vm, {:finished_timer, _}), do: "finished"
  defp stop_reason(_vm, {:runner_deleted, _, _}), do: "timeout"
  defp stop_reason(_vm, :inventory_alive), do: "lost"
  defp stop_reason(_vm, _), do: "admin"

  # The deadline, or a minute when it has passed.
  defp arm_deadline(state) do
    left = remaining_until(state.vm.deadline, DateTime.utc_now())
    arm(state, :deadline, if(left > 0, do: left, else: ms(:deadline_retry)), :deadline)
  end

  defp arm_finished(state, since) do
    now = DateTime.utc_now()
    grace = remaining(since, ms(:finished_grace), now)

    state
    |> disarm(:state)
    |> disarm(:deadline)
    |> arm(:finished_grace, grace, {:finished_timer, :grace})
    |> arm(:finished_force, grace + ms(:finished_force), {:finished_timer, :force})
    |> arm(:check, grace + ms(:finished_force) + ms(:check), :check)
  end

  defp delete_runner_then(state, ref) do
    server = self()
    vm = state.vm
    repo = vm.repo_id |> Repos.get!() |> Repos.with_installation()
    callers = [self() | Process.get(:"$callers", [])]

    Task.start(fn ->
      Process.put(:"$callers", callers)

      # A crash is an error like any other, so the retries cover it:
      # nothing else moves the VM on while it waits.
      result =
        try do
          Client.delete_runner(repo.installation.github_id, repo.full_name, vm.runner_id)
        catch
          kind, error -> {:error, {kind, error}}
        end

      send(server, {:runner_delete_result, ref, result})
    end)
  end

  defp delete_runner_async(vm, runner_id) do
    %{repo_id: vm.repo_id, runner_id: runner_id}
    |> Crew.VMs.DeleteRunner.new()
    |> Oban.insert()
  end

  # -- failure policy (§8.6) and stalls (§8.5) --------------------------------------------

  defp accounting(state, %{state: from}, %{state: "failed", fail_reason: reason})
       when from != "failed" do
    if Machine.quarantine_failure?(reason), do: Boxes.vm_failed(state.vm.box_id)
    if reason not in ~w(lost cp_restart image_not_ready), do: class_failed(state.vm, reason)
    state
  end

  defp accounting(state, _before, %{state: "idle"}) do
    Boxes.vm_succeeded(state.vm.box_id)
    class_set(state.vm, consecutive_failures: 0, backoff_until: nil)
    state
  end

  defp accounting(state, %{state: from}, %{state: "busy"}) when from != "busy" do
    # Any VM of the class going busy clears its stall.
    class_set(state.vm, idle_max_reaps: 0, stalled_until: nil, stall_count: 0)

    state
  end

  # Two idle_max reaps in a row stall the class (§8.5).
  defp accounting(%{reap_why: "idle_max"} = state, %{state: "idle"}, %{
         state: "finished",
         fail_reason: "reaped"
       }) do
    idle_max_reaped(state.vm)
    state
  end

  defp accounting(state, _before, _next), do: state

  # Class accounting is per field and atomic: VMs of a class fail and
  # get reaped at the same moments, and the scheduler writes
  # `excess_since` on the same row.
  defp class_failed(vm, reason) do
    n = class_inc(vm, :consecutive_failures, last_error: reason)

    if n >= @backoff_after do
      seconds = min(300, trunc(:math.pow(2, n - @backoff_after)))
      class_set(vm, backoff_until: DateTime.add(DateTime.utc_now(), seconds, :second))
    end
  end

  @doc false
  def idle_max_reaped(vm) do
    if class_inc(vm, :idle_max_reaps) >= 2 do
      # Only the reap that takes the count back to 0 stalls the class.
      case Repo.update_all(
             class_row(vm) |> where([c], c.idle_max_reaps >= 2) |> select([c], c.stall_count),
             set: [idle_max_reaps: 0, updated_at: DateTime.utc_now()],
             inc: [stall_count: 1]
           ) do
        {1, [count]} -> stall(vm, Enum.at(@stall_minutes, count - 1, List.last(@stall_minutes)))
        _ -> :ok
      end
    end
  end

  defp stall(vm, minutes) do
    class_set(vm, stalled_until: DateTime.add(DateTime.utc_now(), minutes * 60, :second))

    Activity.record(
      "class_stalled",
      "GitHub isn't giving jobs to runners labelled [#{Enum.join(vm.class_key, ", ")}]; holding them for #{minutes} minutes",
      repo_id: vm.repo_id,
      masked: "A class of runners in another repo is stalled"
    )
  end

  defp class_row(vm),
    do: from(c in ClassState, where: c.repo_id == ^vm.repo_id and c.class_hash == ^vm.class_hash)

  defp ensure_class(vm) do
    Repo.insert_all(
      ClassState,
      [
        %{
          repo_id: vm.repo_id,
          class_hash: vm.class_hash,
          class_key: vm.class_key,
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:repo_id, :class_hash]
    )
  end

  defp class_inc(vm, field, set \\ []) do
    ensure_class(vm)

    {1, [n]} =
      Repo.update_all(class_row(vm) |> select([c], field(c, ^field)),
        inc: [{field, 1}],
        set: [updated_at: DateTime.utc_now()] ++ set
      )

    n
  end

  defp class_set(vm, changes) do
    ensure_class(vm)
    Repo.update_all(class_row(vm), set: [updated_at: DateTime.utc_now()] ++ changes)
  end

  # -- timers and helpers ------------------------------------------------------------------

  defp arm(state, name, ms, event) do
    state = disarm(state, name)
    ref = :erlang.start_timer(max(ms, 0), self(), {name, event})
    put_in(state.timers[name], ref)
  end

  defp arm_once(state, name, ms, event) do
    if Map.has_key?(state.timers, name), do: state, else: arm(state, name, ms, event)
  end

  defp disarm(state, name) do
    case Map.pop(state.timers, name) do
      {nil, _} ->
        state

      {ref, timers} ->
        # False when it has already fired; handle_info drops its message.
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  defp disarm_all(state) do
    Enum.each(state.timers, fn {_, ref} -> Process.cancel_timer(ref) end)
    %{state | timers: %{}}
  end

  defp record(state, kind, payload) do
    Repo.insert!(%VMEvent{
      vm_id: state.vm.id,
      kind: kind,
      payload: payload,
      at: DateTime.utc_now()
    })

    state
  end

  defp broadcast(vm) do
    Phoenix.PubSub.broadcast(Crew.PubSub, "vms", {:vm_changed, vm.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "vm:#{vm.id}", {:vm_changed, vm.id})
    Phoenix.PubSub.broadcast(Crew.PubSub, "box:#{vm.box_id}", {:box_changed, vm.box_id})

    if vm.job_id,
      do: Phoenix.PubSub.broadcast(Crew.PubSub, "job:#{vm.job_id}", {:job_changed, vm.job_id})
  end

  defp describe(event) when is_atom(event), do: Atom.to_string(event)
  defp describe(event) when is_tuple(event), do: event |> elem(0) |> Atom.to_string()

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # The JIT config is a credential (§6.3): crash reports and
  # :sys.get_status/1 print the state and the last message, so it's
  # taken out of both.
  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &redact_message/1)
    |> Map.replace_lazy(:queue, fn queue -> Enum.map(queue, &redact_message/1) end)
  end

  defp redact_state(%{jit_config: jit} = state) when is_binary(jit),
    do: %{state | jit_config: "[redacted]"}

  defp redact_state(state), do: state

  defp redact_message({:jit, {:ok, %{jit_config: _} = result}}),
    do: {:jit, {:ok, %{result | jit_config: "[redacted]"}}}

  defp redact_message(message), do: message

  @impl true
  def terminate(_reason, _state), do: :ok
end
