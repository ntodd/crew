// -*- mode: Bluespec; -*-
/**
 * The VM lifecycle (docs/crew_spec.md §8.6, §10.6, §10.7) as three parties
 * that see each other only through messages: the control plane's VM server
 * (Crew.VMs.Server over Crew.VMs.Machine), the box's agent (CrewAgent.VM and
 * CrewAgent.VMs), and GitHub (the JIT runner and the job).
 *
 * One VM, one job, one box. Messages are delayed and reordered where the
 * real channels allow it: the agent link is FIFO each way, commands are
 * dropped when the box is offline, events are kept (the outbox) but lost
 * when the agent restarts, webhooks come in any order or not at all, and
 * the reconciler eventually tells the control plane what GitHub has.
 *
 * `transition` is Crew.VMs.Machine.transition/2 clause for clause. Every
 * control plane step records what it fed the machine and what came back
 * in `steps`, so `quint run --mbt --out-itf` traces replay against the
 * Elixir module (apps/crew/test/crew/vms/machine_replay_test.exs).
 *
 * Run (random simulation, not exhaustive):
 *   quint run models/vm_lifecycle.qnt --invariant=safe --max-samples=20000 --max-steps=60
 */
module vm_lifecycle {
  // ---- Crew.VMs.Machine ------------------------------------------------

  /// The map Machine.transition/2 takes. "" stands in for nil.
  type CpVm = { state: str, reason: str, jobId: str, alive: bool }

  type Event =
    | StartSent
    | StartResult(bool)
    | Booted
    | RunnerListening
    | JobStarted(str)
    | GuestJobStarted
    | JobCompleted(str)
    | Exited({ reason: str, cleanupOk: bool })
    | BoxDisconnected
    | InventoryMissing
    | InventoryAlive
    | Timeout(str)
    | Reap(str)
    | RunnerDeleted({ outcome: str, reason: str })
    | FinishedTimer(str)
    | FailedAliveTick
    | Deadline

  type Effect =
    | RecordStartOp
    | DeleteRunner
    | DeleteRunnerThen(str)
    | Stop(bool)
    | FetchJob
    | LinkJob(str)
    | CancelForceStop
    | ArmFinished
    | Success
    | CleanupFailed

  type Result = Ignored | Ok({ vm: CpVm, effects: Set[Effect] })

  pure val preJob = Set("requested", "starting", "booted", "idle")

  pure def goTo(vm: CpVm, s: str, effs: Set[Effect]): Result =
    Ok({ vm: vm.with("state", s), effects: effs })

  pure def failTo(vm: CpVm, r: str, effs: Set[Effect]): Result =
    Ok({ vm: vm.with("state", "failed").with("reason", r), effects: effs })

  pure def transition(vm: CpVm, ev: Event): Result =
    val s = vm.state
    if (s == "destroyed") Ignored
    else match ev {
      | StartSent =>
        if (s == "requested") Ok({ vm: vm, effects: Set(RecordStartOp) }) else Ignored
      | StartResult(ok) =>
        if (s != "requested") Ignored
        else if (ok) goTo(vm, "starting", Set())
        else failTo(vm, "start_error", Set(DeleteRunner))
      | Booted =>
        if (s == "requested" or s == "starting") goTo(vm, "booted", Set()) else Ignored
      | RunnerListening =>
        if (s == "requested" or s == "starting" or s == "booted") goTo(vm, "idle", Set(Success))
        else Ignored
      | JobStarted(j) =>
        if (preJob.contains(s))
          Ok({ vm: vm.with("jobId", j).with("state", "busy"), effects: Set(LinkJob(j)) })
        else if ((s == "busy" or s == "finished") and vm.jobId == "")
          Ok({ vm: vm.with("jobId", j), effects: Set(LinkJob(j)) })
        else if (s == "failed")
          Ok({ vm: vm.with("state", "busy").with("reason", "").with("jobId", j),
               effects: Set(LinkJob(j), CancelForceStop) })
        else Ignored
      | GuestJobStarted =>
        if (preJob.contains(s)) goTo(vm, "busy", Set())
        else if (s == "failed")
          Ok({ vm: vm.with("state", "busy").with("reason", ""), effects: Set(CancelForceStop) })
        else Ignored
      | JobCompleted(j) =>
        if (s == "busy" and vm.jobId == "")
          Ok({ vm: vm.with("state", "finished").with("jobId", j), effects: Set(LinkJob(j), ArmFinished) })
        else if (preJob.contains(s) or s == "failed")
          Ok({ vm: vm.with("state", "finished").with("reason", "").with("jobId", j),
               effects: Set(LinkJob(j), ArmFinished) })
        else if (s == "busy") goTo(vm, "finished", Set(ArmFinished))
        else if (s == "finished" and vm.jobId == "")
          Ok({ vm: vm.with("jobId", j), effects: Set(LinkJob(j)) })
        else Ignored
      | Exited(e) =>
        if (s == "requested") failTo(vm, "boot_failed", Set(DeleteRunner))
        else if (s == "starting")
          failTo(vm, if (e.reason == "boot_failed") "boot_failed" else "crashed", Set(DeleteRunner))
        else if (s == "booted" or s == "idle") failTo(vm, "crashed", Set(DeleteRunner))
        else if (s == "busy")
          Ok({ vm: vm.with("state", "finished").with("alive", false), effects: Set(ArmFinished) })
        else if (e.cleanupOk)
          Ok({ vm: vm.with("state", "destroyed").with("alive", false), effects: Set() })
        else Ok({ vm: vm.with("alive", false), effects: Set(CleanupFailed) })
      | BoxDisconnected =>
        if (s == "requested") failTo(vm, "lost", Set(DeleteRunner))
        else if (s == "starting" or s == "booted" or s == "idle")
          Ok({ vm: vm, effects: Set(DeleteRunnerThen("lost")) })
        else Ignored
      | InventoryMissing =>
        if (preJob.contains(s)) failTo(vm, "lost", Set(DeleteRunner))
        else if (s == "busy")
          Ok({ vm: vm.with("state", "finished").with("alive", false), effects: Set(ArmFinished) })
        else Ok({ vm: vm.with("state", "destroyed").with("alive", false), effects: Set() })
      | InventoryAlive =>
        if (s == "finished" or s == "failed")
          Ok({ vm: vm.with("alive", true), effects: Set(Stop(true)) })
        else Ignored
      | Timeout(r) =>
        if (s == "requested" and r == "jit_timeout") failTo(vm, "jit_timeout", Set(Stop(true)))
        else if (s == "requested" or s == "starting" or s == "booted")
          Ok({ vm: vm, effects: Set(DeleteRunnerThen(r)) })
        else Ignored
      | Reap(_) =>
        if (s == "idle") Ok({ vm: vm, effects: Set(DeleteRunnerThen("reaped")) }) else Ignored
      | RunnerDeleted(d) =>
        if (s == "idle" and d.outcome == "gone" and d.reason == "reaped")
          Ok({ vm: vm.with("state", "finished").with("reason", "reaped"),
               effects: Set(Stop(false), ArmFinished) })
        else if (preJob.contains(s) and d.outcome == "gone") failTo(vm, d.reason, Set(Stop(true)))
        else if (preJob.contains(s) and d.outcome == "busy")
          Ok({ vm: vm.with("state", "busy").with("reason", ""), effects: Set(FetchJob) })
        else Ignored
      | FinishedTimer(k) =>
        if (s == "finished") Ok({ vm: vm, effects: Set(Stop(k == "force")) }) else Ignored
      | FailedAliveTick =>
        if (s == "failed" and vm.alive) Ok({ vm: vm, effects: Set(Stop(true)) }) else Ignored
      | Deadline =>
        if (s == "busy") Ok({ vm: vm, effects: Set(Stop(true)) }) else Ignored
    }

  // ---- the system ------------------------------------------------------

  /// Control plane -> agent, over the channel.
  type Cmd = CStart | CStop({ force: bool, reason: str }) | CInventory

  /// Agent -> control plane, through the outbox.
  type AgEv =
    | AOpResult(bool)
    | AState(str)
    | AExited({ reason: str, cleanupOk: bool })
    | AInventory({ listed: bool, alive: bool })

  /// One call of Machine.transition/2 and what it answered: `after` and
  /// `effects` are the machine's own (before the server's alive_for and
  /// forced reasons), and `ignored` is its :ignored.
  type Step = { before: CpVm, event: Event, after: CpVm, effects: Set[Effect], ignored: bool }

  type Sys = {
    // -- control plane: the VM server
    cp: CpVm,
    serverUp: bool,          // false once destroyed (the server stops)
    runnerId: bool,          // a JIT config was generated, so a runner exists
    jitPending: bool,        // Client.generate_jit_config in flight
    timers: Set[str],        // jit ack boot runner check deadline fin_grace fin_force
    deletes: Set[str],       // delete_runner_then tasks in flight, by reason
    deleteResults: Set[{ outcome: str, reason: str }],  // their answers, not yet handled
    gcDeletes: int,          // Crew.VMs.DeleteRunner Oban jobs pending
    cpJobState: str,         // the job row: queued | in_progress | completed
    cpJobNamesRunner: bool,  // the job row names this VM's runner
    cpJobLinked: bool,       // Jobs.link_vm happened
    steps: List[Step],       // this action's Machine calls, for replay

    // -- the link
    online: bool,
    toAgent: List[Cmd],
    toCp: List[AgEv],

    // -- agent
    dir: bool,               // vms/<id>/ exists
    vmm: bool,               // the VMM process is alive
    server: bool,            // a CrewAgent.VM server is running
    payload: bool,           // the agent still holds the JIT config
    payloadFetched: bool,
    guestStates: Set[str],
    stopRequested: bool,
    forcedReason: str,
    exitCrashed: bool,
    exitedJson: bool,
    cleanupPending: bool,
    boots: int,

    // -- GitHub
    ghRunner: str,           // none | registered | online | busy | gone
    ghJob: str,              // queued | in_progress | completed
    hooks: Set[str],         // webhooks in flight

    // -- history, for the invariants
    killedDuringJob: bool,
    stopReasonDuringJob: str,

    // -- how many faults a run may still inject (restarts, drops, crashes)
    faults: int
  }

  var S: Sys

  // ---- the server around the machine (Crew.VMs.Server) ------------------

  pure def arm(s: Sys, t: str): Sys =
    // :state is one timer key: the runner timer replaces the boot timer.
    val without = if (t == "boot") Set("runner") else if (t == "runner") Set("boot") else Set()
    s.with("timers", s.timers.exclude(without).union(Set(t)))

  pure def armOnce(s: Sys, t: str): Sys = if (s.timers.contains(t)) s else s.arm(t)

  pure def disarm(s: Sys, t: str): Sys = s.with("timers", s.timers.exclude(Set(t)))

  /// Operations.dispatch: nothing goes to an offline box.
  pure def dispatch(s: Sys, c: Cmd): Sys =
    if (s.online) s.with("toAgent", s.toAgent.append(c)) else s

  pure def stopReason(vm: CpVm, ev: Event): str =
    if (vm.reason == "reaped") "reaped"
    else match ev {
      | Deadline => "deadline"
      | FinishedTimer(_) => "finished"
      | RunnerDeleted(_) => "timeout"
      | InventoryAlive => "lost"
      | _ => "admin"
    }

  pure def rank(st: str): int =
    if (st == "queued") 1 else if (st == "in_progress") 2 else 3

  pure def armFinished(s: Sys): Sys =
    s.disarm("boot").disarm("runner").disarm("deadline")
     .arm("fin_grace").arm("fin_force").arm("check")

  /// The effects but FetchJob, which applies a transition of its own.
  pure def effectLeaf(s: Sys, e: Effect, ev: Event): Sys =
    match e {
      | RecordStartOp => s
      | DeleteRunner => if (s.runnerId) s.with("gcDeletes", s.gcDeletes + 1) else s
      | DeleteRunnerThen(r) =>
        if (s.runnerId) s.with("deletes", s.deletes.union(Set(r)))
        else s.with("deleteResults", s.deleteResults.union(Set({ outcome: "gone", reason: r })))
      | Stop(force) => s.dispatch(CStop({ force: force, reason: stopReason(s.cp, ev) }))
      | FetchJob => s
      | LinkJob(_) => s.with("cpJobLinked", true)
      | CancelForceStop => s.disarm("check")
      | ArmFinished => s.armFinished()
      | Success => s
      | CleanupFailed => s
    }

  pure def afterState(s: Sys): Sys =
    val st = s.cp.state
    if (st == "destroyed") s.with("timers", Set()).with("serverUp", false)
    else if (st == "starting") s.disarm("ack").armOnce("boot")
    else if (st == "booted") s.disarm("ack").arm("runner")
    else if (st == "idle") s.disarm("ack").disarm("boot").disarm("runner")
    else if (st == "busy")
      s.disarm("ack").disarm("check").disarm("boot").disarm("runner").armOnce("deadline")
    else if (st == "failed") s.disarm("ack").disarm("boot").disarm("runner").armOnce("check")
    else s

  pure def carriesOn(ev: Event): bool =
    match ev { | InventoryMissing => true | Exited(_) => true | _ => false }

  /// One Machine call and its effects (Server.apply_transition/3 without
  /// carry_on): persist, alive_for, the effects, after_state.
  pure def applyWith(s: Sys, ev: Event, forceReason: str,
                     eff: (Sys, Effect, Event) => Sys): Sys =
    if (not(s.serverUp)) s
    else match transition(s.cp, ev) {
      | Ignored =>
        s.with("steps", s.steps.append(
          { before: s.cp, event: ev, after: s.cp, effects: Set(), ignored: true }))
      | Ok(r) =>
        val forced =
          if (forceReason != "" and r.vm.state == "failed") r.vm.with("reason", forceReason)
          else r.vm
        // alive_for/2
        val nextVm = match ev {
          | StartResult(ok) => if (ok) forced.with("alive", true) else forced
          | Booted => forced.with("alive", true)
          | _ => forced
        }
        val step = { before: s.cp, event: ev, after: r.vm, effects: r.effects, ignored: false }
        val s1 = s.with("cp", nextVm).with("steps", s.steps.append(step))
        val s2 = r.effects.fold(s1, (acc, e) => eff(acc, e, ev))
        s2.afterState()
    }

  pure def applyLeaf(s: Sys, ev: Event, forceReason: str): Sys =
    applyWith(s, ev, forceReason, effectLeaf)

  /// Every effect. FetchJob (Jobs.find_by_runner_name) links the job the
  /// row already names, through a nested transition.
  pure def effectFull(s: Sys, e: Effect, ev: Event): Sys =
    match e {
      | FetchJob => if (s.cpJobNamesRunner) s.applyLeaf(JobStarted("job"), "") else s
      | _ => effectLeaf(s, e, ev)
    }

  pure def applyOnce(s: Sys, ev: Event, forceReason: str): Sys =
    applyWith(s, ev, forceReason, effectFull)

  /// Server.apply_transition/3 with carry_on/4: a busy VM that exited or
  /// went missing is finished, and the same event then destroys it; one
  /// that did before its job is failed, then destroyed.
  pure def applyEvent(s: Sys, ev: Event, forceReason: str): Sys =
    val from = s.cp.state
    val s1 = s.applyOnce(ev, forceReason)
    if (s1.serverUp and carriesOn(ev) and
        ((from == "busy" and s1.cp.state == "finished") or
         (preJob.contains(from) and s1.cp.state == "failed")))
      s1.applyOnce(ev, "")
    else s1

  pure def fresh(s: Sys): Sys = s.with("steps", [])

  /// Server.send_start/1.
  pure def sendStart(s: Sys): Sys =
    if (s.online) s.with("toAgent", s.toAgent.append(CStart)).arm("ack")
    else s.arm("ack")

  /// The job row after an upsert, then runner_named/1: the VM hears the
  /// job's state now, whatever the event was for.
  pure def deliverJobState(s: Sys, st: str): Sys =
    val now = if (rank(st) > rank(s.cpJobState)) st else s.cpJobState
    val s1 = s.with("cpJobState", now).with("cpJobNamesRunner", true)
    val ev = if (now == "in_progress") JobStarted("job") else JobCompleted("job")
    if (now == "queued") s1
    else if (s1.serverUp) s1.applyEvent(ev, "")
    else s1.with("cpJobLinked", true)   // late_link/2

  pure def rearm(s: Sys): Sys =
    val st = s.cp.state
    if (st == "starting") s.arm("boot")
    else if (st == "booted") s.arm("runner")
    else if (st == "busy") s.arm("deadline")
    else if (st == "finished") s.armFinished()
    else if (st == "failed") s.arm("check")
    else s

  pure def fireTimer(s: Sys, t: str): Sys =
    val s0 = s.disarm(t)
    if (t == "jit") s0.applyEvent(Timeout("jit_timeout"), "")
    else if (t == "ack") s0.applyEvent(Timeout("agent_timeout"), "")
    else if (t == "boot") s0.applyEvent(Timeout("boot_timeout"), "")
    else if (t == "runner") s0.applyEvent(Timeout("runner_timeout"), "")
    else if (t == "fin_grace") s0.applyEvent(FinishedTimer("grace"), "")
    else if (t == "fin_force") s0.applyEvent(FinishedTimer("force"), "")
    else if (t == "check")
      val s1 = if (s0.cp.state == "failed" and s0.cp.alive) s0.applyEvent(FailedAliveTick, "") else s0
      val s2 = s1.dispatch(CInventory)
      if (s2.cp.state == "failed" or s2.cp.state == "finished") s2.arm("check") else s2
    else // deadline
      val s1 = s0.applyEvent(Deadline, "")
      if (s1.cp.state == "busy") s1.dispatch(CInventory) else s1

  pure def handleAgentEvent(s: Sys, e: AgEv): Sys =
    match e {
      | AOpResult(ok) => s.applyEvent(StartResult(ok), "")
      | AState(st) =>
        if (st == "booted") s.applyEvent(Booted, "")
        else if (st == "runner_listening") s.applyEvent(RunnerListening, "")
        else s.applyEvent(GuestJobStarted, "")
      | AExited(x) => s.applyEvent(Exited({ reason: x.reason, cleanupOk: x.cleanupOk }), "")
      | AInventory(i) =>
        // apply_inventory/2 skips a requested VM.
        if (s.cp.state == "requested") s
        else if (not(i.listed)) s.applyEvent(InventoryMissing, "")
        else if (i.alive) s.applyEvent(InventoryAlive, "")
        else s
    }

  // ---- the agent (CrewAgent.VMs, CrewAgent.VM) ---------------------------

  pure def inventoryEntry(s: Sys): AgEv =
    AInventory({ listed: s.dir, alive: s.dir and not(s.exitedJson) and (s.server or s.vmm) })

  pure def emit(s: Sys, e: AgEv): Sys = s.with("toCp", s.toCp.append(e))

  pure def jobRunning(s: Sys): bool = s.vmm and s.ghJob == "in_progress"

  pure def handleCmd(s: Sys, c: Cmd, startOk: bool): Sys =
    match c {
      | CStart =>
        if (s.dir)
          // VMs.existing/1
          s.emit(AOpResult(not(s.exitedJson) and (s.server or s.vmm)))
        else if (startOk)
          s.with("dir", true).with("vmm", true).with("server", true).with("payload", true)
           .with("boots", s.boots + 1).emit(AOpResult(true))
        else s.emit(AOpResult(false))
      | CStop(x) =>
        val killed = jobRunning(s) and x.reason != "deadline"
        val s1 = s.with("killedDuringJob", s.killedDuringJob or killed)
                  .with("stopReasonDuringJob", if (killed) x.reason else s.stopReasonDuringJob)
        if (s1.server)
          if (x.force)
            s1.with("vmm", false).with("stopRequested", true)
              .with("forcedReason", if (s1.forcedReason == "") "killed_stop" else s1.forcedReason)
          else s1.with("stopRequested", true)
        else if (s1.vmm) s1.with("vmm", false)
        else s1
      | CInventory => s.emit(inventoryEntry(s))
    }

  pure def exitReason(s: Sys): str =
    if (s.forcedReason != "") s.forcedReason
    else if (not(s.guestStates.contains("runner_listening"))) "boot_failed"
    else if (s.exitCrashed) "crashed"
    else "poweroff"

  /// CrewAgent.VM.finish/1: exited.json, cleanup, vm.exited.
  pure def finish(s: Sys, cleanupOk: bool): Sys =
    s.with("exitedJson", true).with("cleanupPending", not(cleanupOk)).with("server", false)
     .emit(AExited({ reason: exitReason(s), cleanupOk: cleanupOk }))

  /// §10.7 adoption, after the agent process restarts.
  pure def adopt(s: Sys): Sys =
    val s0 = s.with("payload", false).with("toCp", []).with("server", false)
    if (not(s0.dir) or s0.exitedJson) s0
    else if (not(s0.vmm)) s0.with("server", true)
    else if (not(s0.payloadFetched))
      s0.with("server", true).with("vmm", false).with("forcedReason", "boot_failed")
    else s0.with("server", true)

  // ---- guards and actions ------------------------------------------------

  pure def canJitOk(s: Sys): bool = s.jitPending
  pure def jitOk(s: Sys): Sys =
    val s0 = s.with("jitPending", false).with("ghRunner", "registered")
    if (s0.cp.state == "requested" and s0.serverUp)
      s0.with("runnerId", true).disarm("jit").sendStart()
    else s0.with("gcDeletes", s0.gcDeletes + 1)   // too late: the runner goes

  pure def canTimer(s: Sys): bool = s.timers != Set()

  pure def canDeliverAgent(s: Sys): bool = s.toCp.length() > 0
  pure def deliverAgent(s: Sys): Sys =
    s.with("toCp", s.toCp.tail()).handleAgentEvent(s.toCp.head())

  pure def canDeliverDelete(s: Sys): bool = s.deleteResults != Set()
  pure def deliverDelete(s: Sys, r: { outcome: str, reason: str }): Sys =
    s.with("deleteResults", s.deleteResults.exclude(Set(r)))
     .applyEvent(RunnerDeleted(r), "")

  pure def canHook(s: Sys): bool = s.hooks != Set()
  pure def hook(s: Sys, h: str): Sys =
    s.with("hooks", s.hooks.exclude(Set(h))).deliverJobState(h)

  pure def canReconcile(s: Sys): bool = s.ghJob != s.cpJobState
  pure def reconcile(s: Sys): Sys = s.deliverJobState(s.ghJob)

  pure def canReap(s: Sys): bool = s.serverUp and s.cp.state == "idle"
  pure def reap(s: Sys): Sys = s.applyEvent(Reap("idle_max"), "")

  /// The control plane restarts: tasks, timers and the mailbox go; the
  /// servers come back from the database (Server.init/1, handle_continue(:boot)).
  pure def cpRestart(s: Sys): Sys =
    // The agent's socket goes with the old node; it rejoins the new one.
    val s0 = s.with("jitPending", false).with("deletes", Set()).with("deleteResults", Set())
              .with("timers", Set()).with("online", false).with("toAgent", [])
    if (not(s0.serverUp)) s0
    else if (s0.cp.state == "requested")
      val s1 = if (s0.runnerId) s0.with("gcDeletes", s0.gcDeletes + 1) else s0
      s1.applyEvent(RunnerDeleted({ outcome: "gone", reason: "cp_restart" }), "cp_restart")
    else s0.rearm()

  pure def canDisconnect(s: Sys): bool = s.online
  pure def disconnect(s: Sys): Sys =
    s.with("online", false).with("toAgent", []).applyEvent(BoxDisconnected, "")

  pure def canJoin(s: Sys): bool = not(s.online)
  /// Connection.handle_join/3: the outbox attaches (queued events first),
  /// then the reporter sends the inventory.
  pure def join(s: Sys): Sys = s.with("online", true).emit(inventoryEntry(s))

  pure def canAgentDeliver(s: Sys): bool = s.online and s.toAgent.length() > 0
  pure def agentDeliver(s: Sys, startOk: bool): Sys =
    s.with("toAgent", s.toAgent.tail()).handleCmd(s.toAgent.head(), startOk)

  pure def canAssign(s: Sys): bool = s.ghRunner == "online" and s.ghJob == "queued"
  pure def ghAssign(s: Sys): Sys =
    s.with("ghJob", "in_progress").with("ghRunner", "busy")
     .with("hooks", s.hooks.union(Set("in_progress")))

  /// The job ends: done, or GitHub gave up on a runner that went away.
  /// A JIT runner removes itself with its job.
  pure def canComplete(s: Sys): bool = s.ghJob == "in_progress"
  pure def complete(s: Sys): Sys =
    s.with("ghJob", "completed").with("ghRunner", "gone")
     .with("hooks", s.hooks.union(Set("completed")))

  pure def deleteOutcome(s: Sys): str = if (s.ghRunner == "busy") "busy" else "gone"
  pure def runnerAfterDelete(s: Sys): str = if (s.ghRunner == "busy") "busy" else "gone"

  pure def canGhDelete(s: Sys): bool = s.deletes != Set()
  pure def ghDelete(s: Sys, r: str): Sys =
    s.with("deletes", s.deletes.exclude(Set(r)))
     .with("deleteResults", s.deleteResults.union(Set({ outcome: deleteOutcome(s), reason: r })))
     .with("ghRunner", runnerAfterDelete(s))

  pure def canGcDelete(s: Sys): bool = s.gcDeletes > 0
  pure def gcDelete(s: Sys): Sys =
    s.with("gcDeletes", s.gcDeletes - 1).with("ghRunner", runnerAfterDelete(s))

  pure def canFetchPayload(s: Sys): bool =
    s.vmm and s.server and s.payload and not(s.payloadFetched)
  pure def fetchPayload(s: Sys): Sys =
    s.with("payloadFetched", true).emit(AState("booted"))

  pure def canRunnerUp(s: Sys): bool =
    s.vmm and s.server and s.payloadFetched and s.ghRunner == "registered"
  pure def runnerUp(s: Sys): Sys =
    s.with("ghRunner", "online").with("guestStates", s.guestStates.union(Set("runner_listening")))
     .emit(AState("runner_listening"))

  pure def canGuestJobStarted(s: Sys): bool =
    s.vmm and s.server and s.ghJob == "in_progress" and not(s.guestStates.contains("job_started"))
  pure def guestJobStarted(s: Sys): Sys =
    s.with("guestStates", s.guestStates.union(Set("job_started"))).emit(AState("job_started"))

  pure def canVmmDie(s: Sys): bool = s.vmm
  pure def vmmDie(s: Sys, crashed: bool): Sys = s.with("vmm", false).with("exitCrashed", crashed)

  pure def canGraceOver(s: Sys): bool = s.vmm and s.server and s.stopRequested
  pure def graceOver(s: Sys): Sys =
    s.with("vmm", false).with("forcedReason", if (s.forcedReason == "") "killed_stop" else s.forcedReason)

  pure def canPoll(s: Sys): bool = s.server and not(s.vmm)

  pure def canCleanupRetry(s: Sys): bool = s.cleanupPending
  pure def cleanupRetry(s: Sys): Sys = s.with("cleanupPending", false)

  pure def canSweep(s: Sys): bool = s.dir and s.exitedJson and not(s.cleanupPending)
  pure def sweep(s: Sys): Sys = s.with("dir", false)

  pure def canDup(s: Sys): bool = s.toCp.length() > 0
  /// An ack that didn't land: the outbox sends the event again.
  pure def dup(s: Sys): Sys = s.handleAgentEvent(s.toCp.head())

  pure def initial(faults: int): Sys = {
    cp: { state: "requested", reason: "", jobId: "", alive: false },
    serverUp: true, runnerId: false, jitPending: true, timers: Set("jit"),
    deletes: Set(), deleteResults: Set(), gcDeletes: 0,
    cpJobState: "queued", cpJobNamesRunner: false, cpJobLinked: false, steps: [],
    online: true, toAgent: [], toCp: [],
    dir: false, vmm: false, server: false, payload: false, payloadFetched: false,
    guestStates: Set(), stopRequested: false, forcedReason: "", exitCrashed: false,
    exitedJson: false, cleanupPending: false, boots: 0,
    ghRunner: "none", ghJob: "queued", hooks: Set(),
    killedDuringJob: false, stopReasonDuringJob: "",
    faults: faults
  }

  action init = S' = initial(3)

  /// Nothing goes wrong: for traces that walk the whole lifecycle
  /// (`quint run --init=initCalm`).
  action initCalm = S' = initial(0)

  // Each action starts from a fresh `steps` so a trace state lists only
  // the Machine calls of the action that produced it. Faults spend one of
  // the run's budget, so random runs get past the first few steps.
  pure def spend(s: Sys): Sys = s.with("faults", s.faults - 1)
  pure def canFault(s: Sys): bool = s.faults > 0

  action cpJitOkA = all { canJitOk(S), S' = jitOk(fresh(S)) }
  // A timer that fires while what it waits for is still in flight is a
  // slow message, so it costs a fault; one that fires with nothing in
  // flight is a VM that stalled, and is free.
  pure def quiet(s: Sys): bool = and {
    s.toAgent.length() == 0, s.toCp.length() == 0, s.hooks == Set(),
    s.deletes == Set(), s.deleteResults == Set(), not(s.jitPending), s.gcDeletes == 0
  }
  action cpTimerA = all { canTimer(S), quiet(S) or canFault(S), nondet t = S.timers.oneOf()
                          S' = fireTimer(if (quiet(S)) fresh(S) else spend(fresh(S)), t) }
  action cpDeliverAgentA = all { canDeliverAgent(S), S' = deliverAgent(fresh(S)) }
  action cpDeliverDeleteA = all { canDeliverDelete(S), nondet r = S.deleteResults.oneOf()
                                  S' = deliverDelete(fresh(S), r) }
  action cpHookA = all { canHook(S), nondet h = S.hooks.oneOf()
                         S' = hook(fresh(S), h) }
  action cpHookDropA = all { canHook(S), canFault(S), nondet h = S.hooks.oneOf()
                             S' = spend(fresh(S)).with("hooks", S.hooks.exclude(Set(h))) }
  action cpReconcileA = all { canReconcile(S), S' = reconcile(fresh(S)) }
  action cpReapA = all { canReap(S), S' = reap(fresh(S)) }
  action cpRestartA = all { canFault(S), S' = cpRestart(spend(fresh(S))) }
  action boxDisconnectA = all { canDisconnect(S), canFault(S), S' = disconnect(spend(fresh(S))) }
  action boxJoinA = all { canJoin(S), S' = join(fresh(S)) }
  action agentDeliverOk = all { canAgentDeliver(S), S' = agentDeliver(fresh(S), true) }
  action agentDeliverFail = all { canAgentDeliver(S), canFault(S),
                                  S' = agentDeliver(spend(fresh(S)), false) }
  action agentRestartA = all { canDisconnect(S), canFault(S),
                               S' = adopt(disconnect(spend(fresh(S)))) }
  action ghAssignA = all { canAssign(S), S' = ghAssign(fresh(S)) }
  action ghCompleteA = all { canComplete(S), S' = complete(fresh(S)) }
  action ghDeleteA = all { canGhDelete(S), nondet r = S.deletes.oneOf()
                           S' = ghDelete(fresh(S), r) }
  action ghGcDeleteA = all { canGcDelete(S), S' = gcDelete(fresh(S)) }
  action guestFetchPayloadA = all { canFetchPayload(S), S' = fetchPayload(fresh(S)) }
  action guestRunnerUpA = all { canRunnerUp(S), S' = runnerUp(fresh(S)) }
  action guestJobStartedA = all { canGuestJobStarted(S), S' = guestJobStarted(fresh(S)) }
  action vmmPoweroffA = all { canVmmDie(S), S' = vmmDie(fresh(S), false) }
  action vmmCrashA = all { canVmmDie(S), canFault(S), S' = vmmDie(spend(fresh(S)), true) }
  action agentGraceOverA = all { canGraceOver(S), S' = graceOver(fresh(S)) }
  action agentPollOk = all { canPoll(S), S' = finish(fresh(S), true) }
  action agentPollCleanupFails = all { canPoll(S), canFault(S), S' = finish(spend(fresh(S)), false) }
  action agentCleanupRetryA = all { canCleanupRetry(S), S' = cleanupRetry(fresh(S)) }
  action agentSweepA = all { canSweep(S), S' = sweep(fresh(S)) }
  action dupAgentEventA = all { canDup(S), canFault(S), S' = dup(spend(fresh(S))) }

  action step = any {
    cpJitOkA, cpTimerA, cpDeliverAgentA, cpDeliverDeleteA, cpHookA, cpHookDropA,
    cpReconcileA, cpReapA, cpRestartA, boxDisconnectA, boxJoinA, agentDeliverOk,
    agentDeliverFail, agentRestartA, ghAssignA, ghCompleteA, ghDeleteA, ghGcDeleteA,
    guestFetchPayloadA, guestRunnerUpA, guestJobStartedA, vmmPoweroffA, vmmCrashA,
    agentGraceOverA, agentPollOk, agentPollCleanupFails, agentCleanupRetryA, agentSweepA,
    dupAgentEventA
  }

  /// The same, without the faults: what the system does when nothing goes
  /// wrong from here on. Used for `noDeadlock` and `faultFree` runs.
  pure def productive(s: Sys): bool = or {
    canJitOk(s), canTimer(s), canDeliverAgent(s), canDeliverDelete(s), canHook(s),
    canReconcile(s), canReap(s), canJoin(s), canAgentDeliver(s), canAssign(s),
    canComplete(s), canGhDelete(s), canGcDelete(s), canFetchPayload(s), canRunnerUp(s),
    canGuestJobStarted(s), canGraceOver(s), canPoll(s), canCleanupRetry(s), canSweep(s)
  }

  // ---- invariants --------------------------------------------------------

  /// A destroyed VM holds no allocation, so nothing may still be running.
  val destroyedMeansDead = S.cp.state == "destroyed" implies not(S.vmm)

  /// vm.start is never resent, and the agent treats it as idempotent.
  val noDoubleBoot = S.boots <= 1

  /// Only the deadline stops a VM whose runner is on a job (§8.6: a
  /// timeout deletes the runner first, and 422 means busy).
  val noKillDuringJob = not(S.killedDuringJob)

  /// A runner a destroyed VM had is gone, on its way out, or on a job
  /// (a JIT runner removes itself with its job).
  val noRunnerLeak = S.cp.state == "destroyed" implies or {
    S.ghRunner == "none", S.ghRunner == "gone", S.ghRunner == "busy",
    S.gcDeletes > 0, S.deletes != Set()
  }

  /// A job GitHub ran on this VM is linked to it (§8.6 "link the VM,
  /// whatever the job's classification").
  val jobLinked = S.cpJobNamesRunner implies S.cpJobLinked

  /// A VM that isn't destroyed can still get there without a fault.
  val noDeadlock = S.cp.state == "destroyed" or productive(S)

  val safe = and { destroyedMeansDead, noDoubleBoot, noKillDuringJob, noRunnerLeak, noDeadlock }

  // ---- witnesses: paths the random runs rarely walk ----------------------

  /// A control plane restart while a placement is in flight (§8.6 "vm.start
  /// is never resent"): the VM is failed at once and its runner deleted in
  /// the background, so a VM that booted and took the job meanwhile is
  /// force-stopped when the box rejoins.
  run cpRestartKillsJobTest =
    init.then(cpJitOkA)              // JIT config, vm.start sent
      .then(agentDeliverOk)          // the agent boots the VM; op.result waits in the outbox
      .then(cpRestartA)              // requested -> failed (cp_restart), runner delete queued
      .then(guestFetchPayloadA)
      .then(guestRunnerUpA)
      .then(ghAssignA)               // GitHub gives the runner the job before the delete lands
      .then(boxJoinA)                // the agent rejoins: queued events, then the inventory
      .then(cpDeliverAgentA)         // op.result ok: ignored in failed
      .then(cpDeliverAgentA)         // booted: ignored
      .then(cpDeliverAgentA)         // runner_listening: ignored
      .then(cpDeliverAgentA)         // inventory lists it alive: vm.stop force
      .then(agentDeliverOk)          // the agent kills a VM whose job is running
      .expect(S.killedDuringJob and S.stopReasonDuringJob == "lost")

  /// The same through a dropped link: requested + box_disconnected fails
  /// the VM with a background delete, unlike starting/booted/idle, which
  /// wait for 204 or 422.
  run disconnectKillsJobTest =
    init.then(cpJitOkA)
      .then(agentDeliverOk)
      .then(boxDisconnectA)          // requested -> failed (lost), runner delete queued
      .then(guestFetchPayloadA)
      .then(guestRunnerUpA)
      .then(ghAssignA)
      .then(boxJoinA)
      .then(cpDeliverAgentA).then(cpDeliverAgentA).then(cpDeliverAgentA)
      .then(cpDeliverAgentA)         // inventory alive: vm.stop force
      .then(agentDeliverOk)
      .expect(S.killedDuringJob and S.stopReasonDuringJob == "lost")

  /// A VM that went busy on the guest's hook, then exited with a cleanup
  /// error before GitHub's in_progress arrived: it stays finished, and the
  /// webhook that names it links the job there.
  run finishedLinksJobTest =
    init.then(cpJitOkA).then(agentDeliverOk)
      .then(cpDeliverAgentA)         // starting
      .then(guestFetchPayloadA).then(cpDeliverAgentA)   // booted
      .then(guestRunnerUpA).then(cpDeliverAgentA)       // idle
      .then(ghAssignA)
      .then(guestJobStartedA).then(cpDeliverAgentA)     // busy, no job yet
      .then(ghCompleteA)
      .then(vmmPoweroffA)
      .then(agentPollCleanupFails).then(cpDeliverAgentA) // finished, cleanup failed: stays
      .then(cpHookA)                 // in_progress or completed: linked in finished
      .then(cpHookA)
      .expect(S.cpJobNamesRunner and S.cpJobLinked and S.cp.state == "finished")

  /// The happy path, so the model's plumbing is known to carry a VM
  /// from requested to destroyed.
  run happyPathTest =
    init.then(cpJitOkA).then(agentDeliverOk)
      .then(cpDeliverAgentA)
      .then(guestFetchPayloadA).then(cpDeliverAgentA)
      .then(guestRunnerUpA).then(cpDeliverAgentA)
      .then(ghAssignA).then(cpHookA)                    // busy, linked
      .then(ghCompleteA).then(cpHookA)                  // finished
      .then(vmmPoweroffA).then(agentPollOk).then(cpDeliverAgentA)
      .expect(S.cp.state == "destroyed" and S.cpJobLinked and not(S.killedDuringJob))
}
