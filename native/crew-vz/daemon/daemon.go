// Package daemon is `crew-vz daemon`, crew-vzd (§11.4): the supervisor the
// agent asks to start and stop VMs. Every VM's helper is its child, in its
// own session, so helpers outlive both the agent and the daemon; a
// restarted daemon re-adopts the helpers it finds answering on
// vms/*/ctl.sock.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/ctlproto"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
	"github.com/ntodd/crew/native/crew-vz/helper"
)

const (
	DefaultSocket      = "/Library/Application Support/Crew/vzd.sock"
	DefaultDataDir     = "/Library/Application Support/Crew"
	DefaultMaxDeadline = 72 * time.Hour
	HelperLog          = "vz.log"
	SandboxExec        = "/usr/bin/sandbox-exec"
)

// Options configures the daemon.
type Options struct {
	SocketPath string
	DataDir    string
	// HelperPath is the crew-vz binary; helpers run as `HelperPath run ...`.
	HelperPath string
	// HelperEnv is appended to the helper's environment.
	HelperEnv []string
	Limits    config.Limits
	// SandboxProfile, if set, runs each helper under sandbox-exec with it.
	SandboxProfile string
	// SocketGID, if >= 0, is the group given to the socket. Default -1.
	SocketGID    int
	MaxDeadline  time.Duration
	StartTimeout time.Duration // wait for a new helper's ctl.sock; default 30s
	ForceWait    time.Duration // after stop force, wait this long before SIGKILL; default 5s
	Logger       *slog.Logger
	// Version is this build's, answered to `version`.
	Version string
}

type entry struct {
	vmID     string
	pid      int
	deadline int64
	adopted  bool
	gone     chan struct{} // closed once the helper process is gone

	mu        sync.Mutex
	sigkilled bool
}

// Daemon is crew-vzd.
type Daemon struct {
	o   Options
	log *slog.Logger

	mu  sync.Mutex
	vms map[string]*entry
	// starting guards against two concurrent starts of one VM.
	starting map[string]bool
	// restarting, once `restart` is accepted: no VM starts after it.
	restarting bool
	cancel     context.CancelFunc
}

// Run serves the control socket until ctx is done. Helpers keep running
// after it returns.
func Run(ctx context.Context, o Options) error {
	if o.Logger == nil {
		o.Logger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	if o.SocketPath == "" {
		o.SocketPath = DefaultSocket
	}
	if o.DataDir == "" {
		o.DataDir = DefaultDataDir
	}
	if o.MaxDeadline == 0 {
		o.MaxDeadline = DefaultMaxDeadline
	}
	if o.StartTimeout == 0 {
		o.StartTimeout = 30 * time.Second
	}
	if o.ForceWait == 0 {
		o.ForceWait = 5 * time.Second
	}
	if o.HelperPath == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		if o.HelperPath, err = resolve(exe); err != nil {
			return err
		}
	}
	if !filepath.IsAbs(o.DataDir) || filepath.Clean(o.DataDir) != o.DataDir {
		return fmt.Errorf("data dir %q must be absolute and clean", o.DataDir)
	}
	ctx, stop := context.WithCancel(ctx)
	defer stop()
	d := &Daemon{o: o, log: o.Logger, vms: map[string]*entry{}, starting: map[string]bool{}, cancel: stop}
	d.adoptAll()

	ln, err := ctlproto.Listen(o.SocketPath, 0o660)
	if err != nil {
		return err
	}
	if o.SocketGID > 0 {
		if err := os.Chown(o.SocketPath, -1, o.SocketGID); err != nil {
			ln.Close()
			return err
		}
	}
	d.log.Info("crew-vzd listening", "socket", o.SocketPath, "data_dir", o.DataDir, "adopted", len(d.vms))
	return ctlproto.Serve(ctx, ln, d.handle)
}

func (d *Daemon) vmDir(id string) string      { return filepath.Join(d.o.DataDir, "vms", id) }
func (d *Daemon) configPath(id string) string { return filepath.Join(d.vmDir(id), "vz.json") }

// adoptAll finds helpers that are still running from an earlier daemon,
// and gives a record to every launch whose helper died while no daemon
// was watching (a power loss, or crew-vzd down), so it isn't "lost"
// forever.
func (d *Daemon) adoptAll() {
	socks, _ := filepath.Glob(filepath.Join(d.o.DataDir, "vms", "*", "ctl.sock"))
	for _, s := range socks {
		id := filepath.Base(filepath.Dir(s))
		if !config.ValidVMID(id) {
			continue
		}
		d.tryAdopt(id)
	}
	pids, _ := filepath.Glob(filepath.Join(d.o.DataDir, "vms", "*", helper.PIDFile))
	for _, p := range pids {
		id := filepath.Base(filepath.Dir(p))
		if !config.ValidVMID(id) || d.lookup(id) != nil {
			continue
		}
		if ok, _ := exitrec.Exists(filepath.Join(d.vmDir(id), exitrec.FileName)); ok {
			continue
		}
		pid := readPID(p)
		if pid > 0 && syscall.Kill(pid, 0) == nil {
			// Alive but not answering: watch it, and record its end.
			d.mu.Lock()
			e := &entry{vmID: id, pid: pid, adopted: true, gone: make(chan struct{})}
			d.vms[id] = e
			d.mu.Unlock()
			go d.watchAdopted(e)
			d.log.Warn("watching an unresponsive helper", "vm_id", id, "pid", pid)
			continue
		}
		rec := exitrec.Record{Code: exitrec.CodeError, Reason: exitrec.ReasonHelperDied, At: time.Now(), Detail: "found dead at crew-vzd start"}
		if err := exitrec.Write(filepath.Join(d.vmDir(id), exitrec.FileName), rec); err == nil {
			d.log.Warn("a helper died while crew-vzd was down", "vm_id", id)
		}
	}
}

func readPID(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0
	}
	return pid
}

// tryAdopt adopts the helper answering on vm id's ctl.sock, if any.
func (d *Daemon) tryAdopt(id string) *entry {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resp, err := ctlproto.Call(ctx, filepath.Join(d.vmDir(id), "ctl.sock"), ctlproto.Request{Op: "status"})
	if err != nil || !resp.OK || resp.VM == nil || resp.VM.VMID != id || resp.VM.PID <= 0 {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if e, ok := d.vms[id]; ok {
		return e
	}
	e := &entry{vmID: id, pid: resp.VM.PID, deadline: resp.VM.Deadline, adopted: true, gone: make(chan struct{})}
	d.vms[id] = e
	go d.watchAdopted(e)
	d.log.Info("adopted helper", "vm_id", id, "pid", e.pid)
	return e
}

// watchAdopted polls a helper that isn't our child.
func (d *Daemon) watchAdopted(e *entry) {
	for {
		time.Sleep(250 * time.Millisecond)
		if err := syscall.Kill(e.pid, 0); errors.Is(err, syscall.ESRCH) {
			d.helperGone(e, "")
			return
		}
	}
}

// helperGone records a helper's exit and writes exited.json if the helper
// couldn't.
func (d *Daemon) helperGone(e *entry, status string) {
	d.mu.Lock()
	if d.vms[e.vmID] == e {
		delete(d.vms, e.vmID)
	}
	d.mu.Unlock()
	e.mu.Lock()
	killed := e.sigkilled
	e.mu.Unlock()
	rec := exitrec.Record{Code: exitrec.CodeError, Reason: exitrec.ReasonHelperDied, At: time.Now(), Detail: status}
	if killed {
		rec = exitrec.Record{Code: exitrec.CodeKilled, Reason: exitrec.ReasonKilled, At: time.Now(), Detail: "SIGKILL from crew-vzd after stop force"}
	}
	// Only the daemon-validated location; first writer wins, so the
	// helper's own record is never replaced.
	if err := exitrec.Write(filepath.Join(d.vmDir(e.vmID), exitrec.FileName), rec); err == nil {
		d.log.Warn("helper exited without a record", "vm_id", e.vmID, "status", status)
	}
	close(e.gone)
	d.log.Info("helper exited", "vm_id", e.vmID, "pid", e.pid, "status", status)
}

func (d *Daemon) handle(ctx context.Context, r ctlproto.Request) ctlproto.Response {
	switch r.Op {
	case "list":
		return d.list(ctx)
	case "version":
		return ctlproto.Response{OK: true, Version: d.o.Version}
	case "restart":
		return d.restart()
	case "start", "stop", "status":
	default:
		return ctlproto.Fail(ctlproto.ErrUnknownOp, "unknown op %q", r.Op)
	}
	if !config.ValidVMID(r.VMID) {
		return ctlproto.Fail(ctlproto.ErrBadRequest, "vm_id %q is not valid", r.VMID)
	}
	switch r.Op {
	case "start":
		return d.start(ctx, r)
	case "stop":
		return d.stop(ctx, r)
	default:
		return d.status(ctx, r.VMID)
	}
}

// restart exits crew-vzd, for launchd (KeepAlive) to start it again
// from the release the agent switched to (spec §20.2). Only while no VM
// runs or is starting: helpers outlive the daemon, but a running VM
// keeps the release it started with until it ends. Refused (busy)
// otherwise, and the old crew-vzd keeps serving.
func (d *Daemon) restart() ctlproto.Response {
	d.mu.Lock()
	defer d.mu.Unlock()
	if n := len(d.vms) + len(d.starting); n > 0 {
		return ctlproto.Fail(ctlproto.ErrBusy, "%d VMs are running or starting", n)
	}
	d.restarting = true
	d.log.Info("restarting for an update", "version", d.o.Version)
	// After this answer is written.
	time.AfterFunc(100*time.Millisecond, d.cancel)
	return ctlproto.Response{OK: true}
}

// resolve follows the links in the daemon's own path (launchd runs
// agent/current/bin/crew-vz), so helpers keep coming from the release
// this daemon started from after an update moves current.
func resolve(exe string) (string, error) {
	return filepath.EvalSymlinks(exe)
}

func (d *Daemon) lookup(id string) *entry {
	d.mu.Lock()
	e := d.vms[id]
	d.mu.Unlock()
	if e != nil {
		return e
	}
	// A helper we don't know about (started by a daemon that died before
	// this one scanned) still answers on its ctl.sock.
	return d.tryAdopt(id)
}

func (d *Daemon) start(ctx context.Context, r ctlproto.Request) ctlproto.Response {
	now := time.Now()
	if r.Deadline <= now.Unix() {
		return ctlproto.Fail(ctlproto.ErrBadRequest, "deadline %d is missing or in the past", r.Deadline)
	}
	if time.Unix(r.Deadline, 0).After(now.Add(d.o.MaxDeadline)) {
		return ctlproto.Fail(ctlproto.ErrBadRequest, "deadline more than %v away", d.o.MaxDeadline)
	}
	id := r.VMID
	if _, err := os.Lstat(d.configPath(id)); errors.Is(err, fs.ErrNotExist) {
		return ctlproto.Fail(ctlproto.ErrNotFound, "no vz.json for %s", id)
	}

	d.mu.Lock()
	if d.restarting {
		d.mu.Unlock()
		return ctlproto.Fail(ctlproto.ErrBusy, "crew-vzd is restarting for an update")
	}
	if d.starting[id] {
		d.mu.Unlock()
		return ctlproto.Fail(ctlproto.ErrAlreadyRunning, "%s is being started", id)
	}
	d.starting[id] = true
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.starting, id)
		d.mu.Unlock()
	}()

	if e := d.lookup(id); e != nil {
		return ctlproto.Fail(ctlproto.ErrAlreadyRunning, "%s is running (pid %d)", id, e.pid)
	}
	cfgPath := d.configPath(id)
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return ctlproto.Fail(ctlproto.ErrInvalidConfig, "%v", err)
	}
	if err := cfg.ValidateAt(cfgPath, d.o.DataDir, d.o.Limits); err != nil {
		return ctlproto.Fail(ctlproto.ErrInvalidConfig, "%v", err)
	}
	if ok, _ := exitrec.Exists(cfg.ExitedPath); ok {
		return ctlproto.Fail(ctlproto.ErrAlreadyExited, "%s has exited; its disk is used", id)
	}
	if ok, _ := exitrec.Exists(filepath.Join(d.vmDir(id), helper.PIDFile)); ok {
		return ctlproto.Fail(ctlproto.ErrAlreadyLaunched, "%s was launched before (%s exists)", id, helper.PIDFile)
	}

	e, err := d.launch(cfg, cfgPath, r.Deadline)
	if err != nil {
		return ctlproto.Fail(ctlproto.ErrStartFailed, "%v", err)
	}
	return d.awaitRunning(ctx, e, cfg)
}

func (d *Daemon) helperCommand(cfg *config.Config, cfgPath string, deadline int64) *exec.Cmd {
	args := []string{"run",
		"--config", cfgPath,
		"--deadline", strconv.FormatInt(deadline, 10),
		"--data-dir", d.o.DataDir,
		"--max-vcpus", strconv.Itoa(d.o.Limits.MaxVCPUs),
		"--max-memory-mib", strconv.Itoa(d.o.Limits.MaxMemoryMiB),
	}
	if d.o.SandboxProfile == "" {
		return exec.Command(d.o.HelperPath, args...)
	}
	sb := append(SandboxArgs(d.o.SandboxProfile, d.o.HelperPath, cfg), d.o.HelperPath)
	return exec.Command(SandboxExec, append(sb, args...)...)
}

// SandboxArgs are sandbox-exec's arguments (before the command) for one
// VM's helper: the profile and its parameters (see sandbox.sb). The
// sandbox matches resolved paths, so the parameters are resolved too
// (/tmp is /private/tmp, for one).
func SandboxArgs(profile, helperPath string, cfg *config.Config) []string {
	vmDir := realPath(cfg.VMDir())
	inVMDir := func(p string) string { return filepath.Join(vmDir, filepath.Base(p)) }
	return []string{"-f", profile,
		"-D", "HELPER=" + realPath(helperPath),
		"-D", "VM_DIR=" + vmDir,
		"-D", "KERNEL=" + realPath(cfg.Kernel),
		"-D", "GUEST_SOCK=" + inVMDir(cfg.GuestSocket),
		"-D", "CTL_SOCK=" + inVMDir(cfg.CtlSocket),
	}
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func (d *Daemon) launch(cfg *config.Config, cfgPath string, deadline int64) (*entry, error) {
	logPath := filepath.Join(d.vmDir(cfg.VMID), HelperLog)
	// A fresh inode: whatever is at the path (a hard link to a file
	// elsewhere, say) is replaced, never written through.
	if err := os.Remove(logPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("helper log: %w", err)
	}
	logf, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o640)
	if err != nil {
		return nil, fmt.Errorf("helper log: %w", err)
	}
	defer logf.Close()
	cmd := d.helperCommand(cfg, cfgPath, deadline)
	cmd.Env = append(os.Environ(), d.o.HelperEnv...)
	// stdout/stderr go to a file, never a pipe to us: a helper writing to a
	// pipe whose reader (this daemon) has gone would die of SIGPIPE.
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.Dir = d.vmDir(cfg.VMID)
	// Its own session: launchd's process-group cleanup of crew-vzd, and
	// signals to the daemon's group, don't reach the VMs.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	e := &entry{vmID: cfg.VMID, pid: cmd.Process.Pid, deadline: deadline, gone: make(chan struct{})}
	d.mu.Lock()
	d.vms[cfg.VMID] = e
	d.mu.Unlock()
	d.log.Info("started helper", "vm_id", cfg.VMID, "pid", e.pid, "deadline", deadline, "sandboxed", d.o.SandboxProfile != "")
	go func() {
		err := cmd.Wait()
		status := "exit 0"
		if err != nil {
			status = err.Error()
		}
		d.helperGone(e, status)
	}()
	return e, nil
}

// awaitRunning waits for a new helper to answer on its ctl.sock.
func (d *Daemon) awaitRunning(ctx context.Context, e *entry, cfg *config.Config) ctlproto.Response {
	deadline := time.After(d.o.StartTimeout)
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-e.gone:
			detail := "helper exited during start"
			if rec, err := exitrec.Read(cfg.ExitedPath); err == nil {
				detail = fmt.Sprintf("%s (exit %d): %s", rec.Reason, rec.Code, rec.Detail)
			}
			return ctlproto.Fail(ctlproto.ErrStartFailed, "%s; see %s", detail, filepath.Join(d.vmDir(e.vmID), HelperLog))
		case <-deadline:
			d.kill(e)
			return ctlproto.Fail(ctlproto.ErrStartFailed, "helper didn't come up within %v", d.o.StartTimeout)
		case <-ctx.Done():
			return ctlproto.Fail(ctlproto.ErrInternal, "daemon shutting down")
		case <-tick.C:
			cctx, cancel := context.WithTimeout(ctx, time.Second)
			resp, err := ctlproto.Call(cctx, cfg.CtlSocket, ctlproto.Request{Op: "status"})
			cancel()
			if err == nil && resp.OK && resp.VM != nil && resp.VM.State == string(helper.StateRunning) {
				return resp
			}
		}
	}
}

func (d *Daemon) kill(e *entry) {
	e.mu.Lock()
	e.sigkilled = true
	e.mu.Unlock()
	syscall.Kill(e.pid, syscall.SIGKILL)
}

func (d *Daemon) stop(ctx context.Context, r ctlproto.Request) ctlproto.Response {
	e := d.lookup(r.VMID)
	if e == nil {
		return d.notRunning(r.VMID)
	}
	ctlSock := filepath.Join(d.vmDir(r.VMID), "ctl.sock")
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	resp, err := ctlproto.Call(cctx, ctlSock, ctlproto.Request{Op: "stop", Force: r.Force})
	cancel()
	if !r.Force {
		if err != nil {
			return ctlproto.Fail(ctlproto.ErrInternal, "helper: %v", err)
		}
		return resp
	}
	// Force: the helper stops the VM and exits; if it doesn't, kill it.
	select {
	case <-e.gone:
	case <-time.After(d.o.ForceWait):
		d.log.Warn("helper didn't exit after stop force; killing it", "vm_id", r.VMID, "pid", e.pid)
		d.kill(e)
		select {
		case <-e.gone:
		case <-time.After(5 * time.Second):
			return ctlproto.Fail(ctlproto.ErrInternal, "helper %d survived SIGKILL", e.pid)
		}
	}
	return d.status(ctx, r.VMID)
}

func (d *Daemon) notRunning(id string) ctlproto.Response {
	resp := d.status(context.Background(), id)
	if !resp.OK {
		return resp
	}
	if resp.VM.State == "exited" {
		return resp // stopping an exited VM is a no-op
	}
	return ctlproto.Fail(ctlproto.ErrNotRunning, "%s is %s", id, resp.VM.State)
}

func (d *Daemon) status(ctx context.Context, id string) ctlproto.Response {
	if e := d.lookup(id); e != nil {
		cctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		resp, err := ctlproto.Call(cctx, filepath.Join(d.vmDir(id), "ctl.sock"), ctlproto.Request{Op: "status"})
		cancel()
		if err == nil && resp.OK {
			return resp
		}
		select {
		case <-e.gone:
		default:
			// Alive but not answering (still starting, or wedged).
			return ctlproto.Response{OK: true, VM: &ctlproto.VMStatus{VMID: id, State: "unresponsive", PID: e.pid, Deadline: e.deadline}}
		}
	}
	dir := d.vmDir(id)
	if _, err := os.Lstat(dir); err != nil {
		return ctlproto.Fail(ctlproto.ErrNotFound, "no VM %s", id)
	}
	if rec, err := exitrec.Read(filepath.Join(dir, exitrec.FileName)); err == nil {
		return ctlproto.Response{OK: true, VM: &ctlproto.VMStatus{VMID: id, State: "exited", Exited: &rec}}
	}
	state := "not_started"
	if ok, _ := exitrec.Exists(filepath.Join(dir, helper.PIDFile)); ok {
		state = "lost" // launched, no helper, no record yet
	}
	return ctlproto.Response{OK: true, VM: &ctlproto.VMStatus{VMID: id, State: state}}
}

func (d *Daemon) list(ctx context.Context) ctlproto.Response {
	d.mu.Lock()
	entries := make([]*entry, 0, len(d.vms))
	for _, e := range d.vms {
		entries = append(entries, e)
	}
	d.mu.Unlock()
	out := make([]ctlproto.VMStatus, len(entries))
	var wg sync.WaitGroup
	for i, e := range entries {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out[i] = ctlproto.VMStatus{VMID: e.vmID, State: "unresponsive", PID: e.pid, Deadline: e.deadline}
			cctx, cancel := context.WithTimeout(ctx, time.Second)
			defer cancel()
			resp, err := ctlproto.Call(cctx, filepath.Join(d.vmDir(e.vmID), "ctl.sock"), ctlproto.Request{Op: "status"})
			if err == nil && resp.OK && resp.VM != nil {
				out[i] = *resp.VM
				out[i].Net = nil
			}
		}()
	}
	wg.Wait()
	return ctlproto.Response{OK: true, VMs: out}
}
