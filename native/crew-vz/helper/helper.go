// Package helper is `crew-vz run`: one VM, its network, its console, its
// control socket and its exit record (§11.4). The hypervisor is behind the
// Machine interface so the lifecycle rules are testable without VZ.
package helper

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/consolelog"
	"github.com/ntodd/crew/native/crew-vz/ctlproto"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
	"github.com/ntodd/crew/native/crew-vz/netpolicy"
	"github.com/ntodd/crew/native/crew-vz/netstack"
)

// PIDFile is created exclusively in the VM's directory before anything
// else happens, and never removed: its presence means this VM directory
// has been launched once, so even a helper killed before it could write
// exited.json can't be relaunched on the same disk.
const PIDFile = "vz.pid"

// State is the VM's state as reported on ctl.sock.
type State string

const (
	StateStarting State = "starting"
	StateRunning  State = "running"
	StateStopping State = "stopping"
	StateStopped  State = "stopped"
	StateError    State = "error"
)

// MachineSpec is what a Machine is built from.
type MachineSpec struct {
	Config     *config.Config
	Net        *os.File // the VM's end of the frame socketpair
	ConsoleOut *os.File // guest console output is written here
	ConsoleIn  *os.File // guest console input is read from here
}

// Machine is a VM. StateChanges must deliver every transition.
type Machine interface {
	Start() error       // returns once the VM is running (or failed)
	RequestStop() error // the guest's power button
	Stop() error        // pull the plug
	State() State
	StateChanges() <-chan State
}

// Options for Run.
type Options struct {
	ConfigPath string
	// DataDir is the data dir; ConfigPath must be DataDir/vms/<id>/vz.json.
	// Empty means derive it from ConfigPath.
	DataDir    string
	Deadline   time.Time
	Limits     config.Limits
	NewMachine func(MachineSpec) (Machine, error)
	Logger     *slog.Logger
	// StopTimeout bounds the wait for the VM to stop after Stop. Default 15s.
	StopTimeout time.Duration
}

// Run runs one VM to completion and returns the process exit code: 0 the
// guest stopped, 1 error, 2 killed, 3 deadline. Cancelling ctx (a signal)
// kills the VM. Once the VM directory is claimed, every exit writes
// exited.json.
func Run(ctx context.Context, o Options) int {
	log := o.Logger
	if log == nil {
		log = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	if o.StopTimeout == 0 {
		o.StopTimeout = 15 * time.Second
	}
	dataDir := o.DataDir
	if dataDir == "" {
		dataDir = filepath.Dir(filepath.Dir(filepath.Dir(filepath.Clean(o.ConfigPath))))
	}
	cfg, err := config.Load(o.ConfigPath)
	if err != nil {
		log.Error("refusing to start: bad config", "err", err)
		return exitrec.CodeError
	}
	if err := cfg.ValidateAt(o.ConfigPath, dataDir, o.Limits); err != nil {
		log.Error("refusing to start: invalid config", "err", err)
		return exitrec.CodeError
	}
	log = log.With("vm_id", cfg.VMID)
	if ok, err := exitrec.Exists(cfg.ExitedPath); err != nil || ok {
		log.Error("refusing to start: exited.json exists, the disk has been used", "path", cfg.ExitedPath, "err", err)
		return exitrec.CodeError
	}
	if err := claim(filepath.Join(cfg.VMDir(), PIDFile)); err != nil {
		log.Error("refusing to start: this VM was launched before", "err", err)
		return exitrec.CodeError
	}
	r := &runner{o: o, cfg: cfg, log: log, stopReq: make(chan stopReq), exiting: make(chan struct{})}
	code, reason, detail := r.run(ctx)
	rec := exitrec.Record{Code: code, Reason: reason, At: time.Now(), Detail: detail}
	if err := exitrec.Write(cfg.ExitedPath, rec); err != nil {
		log.Error("writing exited.json", "err", err)
	}
	log.Info("exited", "code", code, "reason", reason, "detail", detail)
	return code
}

func claim(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o640)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("%s exists", path)
		}
		return err
	}
	defer f.Close()
	_, err = f.WriteString(strconv.Itoa(os.Getpid()) + "\n")
	return err
}

type stopReq struct {
	force bool
	reply chan error
}

type runner struct {
	o   Options
	cfg *config.Config
	log *slog.Logger

	mu        sync.Mutex
	machine   Machine
	ns        *netstack.Netstack
	console   *consolelog.Writer
	startedAt time.Time

	stopReq chan stopReq
	exiting chan struct{}
}

type stopKind int

const (
	stopNone stopKind = iota
	stopGraceful
	stopForce
	stopDeadline
	stopSignal
)

func (r *runner) run(ctx context.Context) (int, string, string) {
	cfg := r.cfg
	fail := func(format string, args ...any) (int, string, string) {
		return exitrec.CodeError, exitrec.ReasonError, fmt.Sprintf(format, args...)
	}
	if !time.Now().Before(r.o.Deadline) {
		return exitrec.CodeDeadline, exitrec.ReasonDeadline, "deadline passed before boot"
	}

	console, err := consolelog.Open(cfg.ConsoleLog, consolelog.Options{})
	if err != nil {
		return fail("console: %v", err)
	}
	defer console.Close()
	consoleR, consoleW, err := os.Pipe()
	if err != nil {
		return fail("console pipe: %v", err)
	}
	defer consoleR.Close()
	defer consoleW.Close()
	inR, inW, err := os.Pipe() // nothing is ever written to the guest
	if err != nil {
		return fail("console pipe: %v", err)
	}
	defer inR.Close()
	defer inW.Close()
	copied := make(chan struct{})
	go func() {
		io.Copy(console, consoleR)
		close(copied)
	}()
	flushDone := make(chan struct{})
	defer close(flushDone)
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				console.Flush()
			case <-flushDone:
				return
			}
		}
	}()

	n := cfg.Net()
	vmNet, helperNet, err := netstack.Socketpair(n.MTU)
	if err != nil {
		return fail("network: %v", err)
	}
	defer vmNet.Close()
	ns, err := netstack.New(netstack.Options{
		Policy: &netpolicy.Policy{
			Gateway: n.Gateway, Guest: n.Guest, ServiceIP: n.ServiceIP,
			CacheAddr: n.CacheAddr, DNSFallback: n.DNSFallback, Site4: n.Site4,
		},
		Limiter:     netpolicy.NewConnLimiter(n.MaxConns),
		GuestMAC:    n.GuestMAC,
		MTU:         n.MTU,
		GuestSocket: cfg.GuestSocket,
		Logger:      r.log,
	})
	if err != nil {
		helperNet.Close()
		return fail("network: %v", err)
	}
	defer ns.Close()
	go func() {
		if err := ns.Run(helperNet); err != nil {
			r.log.Error("network link", "err", err)
		}
	}()

	m, err := r.o.NewMachine(MachineSpec{Config: cfg, Net: vmNet, ConsoleOut: consoleW, ConsoleIn: inR})
	if err != nil {
		return fail("configure VM: %v", err)
	}
	r.mu.Lock()
	r.machine, r.ns, r.console = m, ns, console
	r.mu.Unlock()

	ln, err := ctlproto.Listen(cfg.CtlSocket, 0o660)
	if err != nil {
		return fail("ctl socket: %v", err)
	}
	ctlCtx, ctlCancel := context.WithCancel(context.Background())
	ctlDone := make(chan struct{})
	go func() {
		ctlproto.Serve(ctlCtx, ln, r.handle)
		close(ctlDone)
	}()
	defer func() {
		close(r.exiting)
		ctlCancel()
		<-ctlDone
	}()

	r.mu.Lock()
	r.startedAt = time.Now()
	r.mu.Unlock()
	r.log.Info("starting VM", "vcpus", cfg.VCPUs, "memory_mib", cfg.MemoryMiB, "deadline", r.o.Deadline.Unix())
	startErr := make(chan error, 1)
	go func() { startErr <- m.Start() }()

	code, reason, detail := r.loop(ctx, m, startErr)

	// Drain the console before publishing exited.json, so console.log is
	// complete when the agent sees the record.
	consoleW.Close()
	select {
	case <-copied:
	case <-time.After(time.Second):
		consoleR.Close()
		<-copied
	}
	return code, reason, detail
}

func (r *runner) loop(ctx context.Context, m Machine, startErr <-chan error) (int, string, string) {
	deadline := time.NewTimer(time.Until(r.o.Deadline))
	defer deadline.Stop()
	var stopping stopKind
	var watchdog <-chan time.Time
	done := ctx.Done()

	hardStop := func(kind stopKind) {
		if stopping < stopForce || kind > stopping {
			stopping = kind
		}
		if watchdog == nil {
			watchdog = time.After(r.o.StopTimeout)
		}
		go func() {
			if err := m.Stop(); err != nil {
				r.log.Warn("stop", "err", err)
			}
		}()
	}
	result := func() (int, string, string) {
		switch stopping {
		case stopForce:
			return exitrec.CodeKilled, exitrec.ReasonKilled, "stop force"
		case stopSignal:
			return exitrec.CodeKilled, exitrec.ReasonKilled, "signal"
		case stopDeadline:
			return exitrec.CodeDeadline, exitrec.ReasonDeadline, ""
		case stopGraceful:
			return exitrec.CodeClean, exitrec.ReasonGuestStopped, "stop requested"
		}
		return exitrec.CodeClean, exitrec.ReasonGuestStopped, ""
	}

	for {
		select {
		case err := <-startErr:
			if err != nil {
				if stopping >= stopForce {
					return result() // stopped while starting
				}
				return exitrec.CodeError, exitrec.ReasonError, fmt.Sprintf("start VM: %v", err)
			}
			r.log.Info("VM running")
		case st := <-m.StateChanges():
			switch st {
			case StateStopped:
				return result()
			case StateError:
				if stopping >= stopForce {
					return result()
				}
				return exitrec.CodeError, exitrec.ReasonError, "virtual machine entered the error state"
			}
		case req := <-r.stopReq:
			if req.force {
				hardStop(stopForce)
				req.reply <- nil
				continue
			}
			err := m.RequestStop()
			if err == nil && stopping == stopNone {
				stopping = stopGraceful
			}
			req.reply <- err
		case <-deadline.C:
			r.log.Warn("deadline reached, stopping VM")
			hardStop(stopDeadline)
		case <-done:
			done = nil
			hardStop(stopSignal)
		case <-watchdog:
			code, reason, detail := result()
			return code, reason, joinDetail(detail, "VM did not stop in time")
		}
	}
}

func joinDetail(a, b string) string {
	if a == "" {
		return b
	}
	return a + "; " + b
}

func (r *runner) handle(ctx context.Context, req ctlproto.Request) ctlproto.Response {
	switch req.Op {
	case "status":
		return ctlproto.Response{OK: true, VM: r.status()}
	case "stop":
		sr := stopReq{force: req.Force, reply: make(chan error, 1)}
		select {
		case r.stopReq <- sr:
		case <-r.exiting:
			return ctlproto.Fail(ctlproto.ErrNotRunning, "VM is exiting")
		case <-time.After(10 * time.Second):
			return ctlproto.Fail(ctlproto.ErrInternal, "helper busy")
		}
		if err := <-sr.reply; err != nil {
			return ctlproto.Fail(ctlproto.ErrCannotStop, "%v", err)
		}
		return ctlproto.Response{OK: true, VM: r.status()}
	}
	return ctlproto.Fail(ctlproto.ErrUnknownOp, "unknown op %q", req.Op)
}

func (r *runner) status() *ctlproto.VMStatus {
	r.mu.Lock()
	m, ns, console, started := r.machine, r.ns, r.console, r.startedAt
	r.mu.Unlock()
	st := &ctlproto.VMStatus{
		VMID:     r.cfg.VMID,
		State:    string(StateStarting),
		PID:      os.Getpid(),
		Deadline: r.o.Deadline.Unix(),
	}
	if m != nil {
		st.State = string(m.State())
		if st.State == "" {
			st.State = string(StateStarting)
		}
	}
	if !started.IsZero() {
		st.StartedAt = started.UTC().Format(time.RFC3339Nano)
		st.UptimeS = time.Since(started).Seconds()
	}
	if console != nil {
		st.ConsoleBytes = console.Written()
	}
	if ns != nil {
		if b, err := json.Marshal(ns.Stats()); err == nil {
			st.Net = b
		}
	}
	return st
}
