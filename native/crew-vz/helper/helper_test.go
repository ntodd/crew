package helper

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/ctlproto"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
)

var limits = config.Limits{MinVCPUs: 1, MaxVCPUs: 8, MinMemoryMiB: 256, MaxMemoryMiB: 8192}

type env struct {
	dataDir string
	vmDir   string
	cfgPath string
	cfg     *config.Config
}

// newEnv lays out <data>/images/img/Image and <data>/vms/vm1/{rootfs,vz.json}.
func newEnv(t *testing.T) *env {
	t.Helper()
	data, err := os.MkdirTemp("/tmp", "cvzh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(data) })
	vmDir := filepath.Join(data, "vms", "vm1")
	os.MkdirAll(vmDir, 0o750)
	kernel := filepath.Join(data, "images", "img", "Image")
	os.MkdirAll(filepath.Dir(kernel), 0o755)
	img := make([]byte, 4096)
	binary.LittleEndian.PutUint32(img[0x38:], 0x644d5241)
	os.WriteFile(kernel, img, 0o644)
	disk := filepath.Join(vmDir, "rootfs.ext4")
	os.WriteFile(disk, make([]byte, 1<<20), 0o640)
	cfg := &config.Config{
		VMID: "vm1", VCPUs: 1, MemoryMiB: 512,
		Kernel: kernel, Cmdline: "console=hvc0", Disk: disk,
		ConsoleLog:  filepath.Join(vmDir, "console.log"),
		GuestSocket: filepath.Join(vmDir, "guest.sock"),
		CtlSocket:   filepath.Join(vmDir, "ctl.sock"),
		ExitedPath:  filepath.Join(vmDir, "vz-exited.json"),
		Lease:       config.Lease{Gateway: "10.200.0.1/30", Guest: "10.200.0.2/30", MAC: "02:00:0a:c8:00:02"},
	}
	e := &env{dataDir: data, vmDir: vmDir, cfgPath: filepath.Join(vmDir, "vz.json"), cfg: cfg}
	e.writeConfig(t)
	return e
}

func (e *env) writeConfig(t *testing.T) {
	raw, _ := json.Marshal(e.cfg)
	if err := os.WriteFile(e.cfgPath, raw, 0o640); err != nil {
		t.Fatal(err)
	}
}

// fakeMachine stands in for Virtualization.framework.
type fakeMachine struct {
	mu        sync.Mutex
	state     State
	ch        chan State
	spec      MachineSpec
	startErr  error
	ignoreReq bool // guest ignores the power button
	stopCalls int
	reqCalls  int
}

func (f *fakeMachine) set(s State) {
	f.mu.Lock()
	f.state = s
	f.mu.Unlock()
	f.ch <- s
}

func (f *fakeMachine) Start() error {
	if f.startErr != nil {
		return f.startErr
	}
	f.set(StateStarting)
	f.set(StateRunning)
	return nil
}

func (f *fakeMachine) RequestStop() error {
	f.mu.Lock()
	f.reqCalls++
	st, ignore := f.state, f.ignoreReq
	f.mu.Unlock()
	if st != StateRunning {
		return errors.New("not running")
	}
	if !ignore {
		go func() { time.Sleep(20 * time.Millisecond); f.set(StateStopped) }()
	}
	return nil
}

func (f *fakeMachine) Stop() error {
	f.mu.Lock()
	f.stopCalls++
	f.mu.Unlock()
	f.set(StateStopped)
	return nil
}

func (f *fakeMachine) State() State {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state
}

func (f *fakeMachine) StateChanges() <-chan State { return f.ch }

type run struct {
	e       *env
	machine *fakeMachine
	created chan struct{}
	done    chan int
	cancel  context.CancelFunc
}

func startRun(t *testing.T, e *env, deadline time.Time, prep func(*fakeMachine)) *run {
	t.Helper()
	r := &run{e: e, machine: &fakeMachine{ch: make(chan State, 16)}, created: make(chan struct{}), done: make(chan int, 1)}
	if prep != nil {
		prep(r.machine)
	}
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel = cancel
	t.Cleanup(cancel)
	go func() {
		r.done <- Run(ctx, Options{
			ConfigPath: e.cfgPath,
			DataDir:    e.dataDir,
			Deadline:   deadline,
			Limits:     limits,
			NewMachine: func(s MachineSpec) (Machine, error) {
				r.machine.spec = s
				close(r.created)
				return r.machine, nil
			},
		})
	}()
	return r
}

func (r *run) wait(t *testing.T) int {
	t.Helper()
	select {
	case code := <-r.done:
		return code
	case <-time.After(10 * time.Second):
		t.Fatal("helper did not exit")
		return -1
	}
}

func (r *run) waitCtl(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := ctlproto.Call(context.Background(), r.e.cfg.CtlSocket, ctlproto.Request{Op: "status"})
		if err == nil && resp.OK && resp.VM.State == string(StateRunning) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("ctl.sock never reported running")
}

func (r *run) ctl(t *testing.T, req ctlproto.Request) ctlproto.Response {
	t.Helper()
	resp, err := ctlproto.Call(context.Background(), r.e.cfg.CtlSocket, req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func readExited(t *testing.T, e *env) exitrec.Record {
	t.Helper()
	rec, err := exitrec.Read(e.cfg.ExitedPath)
	if err != nil {
		t.Fatalf("exited.json: %v", err)
	}
	return rec
}

func future() time.Time { return time.Now().Add(time.Hour) }

func TestCleanGuestStop(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	r.machine.set(StateStopped) // the guest powers off
	if code := r.wait(t); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	rec := readExited(t, e)
	if rec.Code != 0 || rec.Reason != exitrec.ReasonGuestStopped {
		t.Fatalf("exited.json %+v", rec)
	}
	if _, err := os.Lstat(e.cfg.CtlSocket); !os.IsNotExist(err) {
		t.Fatal("ctl.sock left behind")
	}
}

func TestForceStop(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	if resp := r.ctl(t, ctlproto.Request{Op: "stop", Force: true}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	if code := r.wait(t); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if rec := readExited(t, e); rec.Code != 2 || rec.Reason != exitrec.ReasonKilled {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestGracefulStop(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	if resp := r.ctl(t, ctlproto.Request{Op: "stop"}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	if code := r.wait(t); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	if r.machine.reqCalls != 1 || r.machine.stopCalls != 0 {
		t.Fatalf("requestStop %d, stop %d", r.machine.reqCalls, r.machine.stopCalls)
	}
	if rec := readExited(t, e); rec.Code != 0 {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestGracefulThenForce(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), func(m *fakeMachine) { m.ignoreReq = true })
	r.waitCtl(t)
	r.ctl(t, ctlproto.Request{Op: "stop"})
	time.Sleep(50 * time.Millisecond)
	if resp := r.ctl(t, ctlproto.Request{Op: "status"}); !resp.OK || resp.VM.State != "running" {
		t.Fatalf("status after ignored stop: %+v", resp)
	}
	r.ctl(t, ctlproto.Request{Op: "stop", Force: true})
	if code := r.wait(t); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
}

func TestDeadline(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, time.Now().Add(400*time.Millisecond), nil)
	if code := r.wait(t); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	if r.machine.stopCalls != 1 {
		t.Fatal("deadline did not stop the machine")
	}
	if rec := readExited(t, e); rec.Code != 3 || rec.Reason != exitrec.ReasonDeadline {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestDeadlineAlreadyPassed(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, time.Now().Add(-time.Second), nil)
	if code := r.wait(t); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	select {
	case <-r.created:
		t.Fatal("machine created past the deadline")
	default:
	}
	if rec := readExited(t, e); rec.Code != 3 {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestRefusesWhenExitedExists(t *testing.T) {
	e := newEnv(t)
	prior := exitrec.Record{Code: 0, Reason: exitrec.ReasonGuestStopped, At: time.Unix(1_700_000_000, 0)}
	exitrec.Write(e.cfg.ExitedPath, prior)
	r := startRun(t, e, future(), nil)
	if code := r.wait(t); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	select {
	case <-r.created:
		t.Fatal("machine created for a used disk")
	default:
	}
	if rec := readExited(t, e); !rec.At.Equal(prior.At) {
		t.Fatalf("exited.json replaced: %+v", rec)
	}
}

func TestRefusesRelaunchAfterCrash(t *testing.T) {
	// A helper that died without writing exited.json leaves vz.pid.
	e := newEnv(t)
	os.WriteFile(filepath.Join(e.vmDir, PIDFile), []byte("12345\n"), 0o640)
	r := startRun(t, e, future(), nil)
	if code := r.wait(t); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	select {
	case <-r.created:
		t.Fatal("machine created after a previous launch")
	default:
	}
	if ok, _ := exitrec.Exists(e.cfg.ExitedPath); ok {
		t.Fatal("wrote exited.json for a launch it refused")
	}
}

func TestInvalidConfig(t *testing.T) {
	e := newEnv(t)
	e.cfg.VCPUs = 99
	e.writeConfig(t)
	r := startRun(t, e, future(), nil)
	if code := r.wait(t); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if ok, _ := exitrec.Exists(e.cfg.ExitedPath); ok {
		t.Fatal("exited.json written from an unvalidated config")
	}
}

func TestStartFailure(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), func(m *fakeMachine) { m.startErr = errors.New("VZErrorDomain 2: invalid kernel") })
	if code := r.wait(t); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	rec := readExited(t, e)
	if rec.Code != 1 || rec.Reason != exitrec.ReasonError || !strings.Contains(rec.Detail, "invalid kernel") {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestMachineError(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	r.machine.set(StateError)
	if code := r.wait(t); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if rec := readExited(t, e); rec.Code != 1 {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestStatus(t *testing.T) {
	e := newEnv(t)
	deadline := future()
	r := startRun(t, e, deadline, nil)
	r.waitCtl(t)
	resp := r.ctl(t, ctlproto.Request{Op: "status"})
	vm := resp.VM
	if !resp.OK || vm.VMID != "vm1" || vm.PID != os.Getpid() || vm.Deadline != deadline.Unix() || vm.StartedAt == "" {
		t.Fatalf("status %+v / %+v", resp, vm)
	}
	var net map[string]any
	if err := json.Unmarshal(vm.Net, &net); err != nil || net["conns_open"] == nil {
		t.Fatalf("net stats %s: %v", vm.Net, err)
	}
	if resp := r.ctl(t, ctlproto.Request{Op: "reboot"}); resp.OK || resp.Error != ctlproto.ErrUnknownOp {
		t.Fatalf("unknown op: %+v", resp)
	}
	r.machine.set(StateStopped)
	r.wait(t)
}

func TestSignalKills(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	r.cancel()
	if code := r.wait(t); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if rec := readExited(t, e); rec.Code != 2 || rec.Reason != exitrec.ReasonKilled || rec.Detail != "signal" {
		t.Fatalf("exited.json %+v", rec)
	}
}

func TestConsoleIsCaptured(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	r.machine.spec.ConsoleOut.Write([]byte("Linux version 6.18\nhello from the guest\n"))
	time.Sleep(50 * time.Millisecond)
	r.machine.set(StateStopped)
	r.wait(t)
	b, _ := os.ReadFile(e.cfg.ConsoleLog)
	if !strings.Contains(string(b), "hello from the guest") {
		t.Fatalf("console.log = %q", b)
	}
}

func TestMachineSpec(t *testing.T) {
	e := newEnv(t)
	r := startRun(t, e, future(), nil)
	r.waitCtl(t)
	s := r.machine.spec
	if s.Config.VMID != "vm1" || s.Net == nil || s.ConsoleOut == nil || s.ConsoleIn == nil {
		t.Fatalf("spec %+v", s)
	}
	r.machine.set(StateStopped)
	r.wait(t)
}
