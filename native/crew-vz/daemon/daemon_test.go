package daemon

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/ctlproto"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
	"github.com/ntodd/crew/native/crew-vz/helper"
)

var limits = config.Limits{MinVCPUs: 1, MaxVCPUs: 4, MinMemoryMiB: 256, MaxMemoryMiB: 4096}

// The test binary doubles as the helper: crew-vzd runs it as
// `<test binary> run --config ... --deadline ...`.
func TestMain(m *testing.M) {
	if os.Getenv("CREW_VZD_FAKE_HELPER") == "1" {
		os.Exit(fakeHelper(os.Args[1:]))
	}
	os.Exit(m.Run())
}

func fakeHelper(args []string) int {
	if len(args) == 0 || args[0] != "run" {
		return 64
	}
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	cfgPath := fs.String("config", "", "")
	deadline := fs.Int64("deadline", 0, "")
	dataDir := fs.String("data-dir", "", "")
	fs.Int("max-vcpus", 0, "")
	fs.Int("max-memory-mib", 0, "")
	if err := fs.Parse(args[1:]); err != nil {
		return 64
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	hang := os.Getenv("CREW_VZD_FAKE_HANG") == "1"
	return helper.Run(ctx, helper.Options{
		ConfigPath: *cfgPath, DataDir: *dataDir, Deadline: time.Unix(*deadline, 0), Limits: limits,
		NewMachine: func(helper.MachineSpec) (helper.Machine, error) {
			return &fakeMachine{ch: make(chan helper.State, 16), hang: hang}, nil
		},
	})
}

type fakeMachine struct {
	mu    sync.Mutex
	state helper.State
	ch    chan helper.State
	hang  bool // Stop never completes: the VM is wedged
}

func (f *fakeMachine) set(s helper.State) {
	f.mu.Lock()
	f.state = s
	f.mu.Unlock()
	f.ch <- s
}
func (f *fakeMachine) Start() error { f.set(helper.StateRunning); return nil }
func (f *fakeMachine) RequestStop() error {
	go func() { time.Sleep(30 * time.Millisecond); f.set(helper.StateStopped) }()
	return nil
}
func (f *fakeMachine) Stop() error {
	if f.hang {
		select {}
	}
	f.set(helper.StateStopped)
	return nil
}
func (f *fakeMachine) State() helper.State {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state
}
func (f *fakeMachine) StateChanges() <-chan helper.State { return f.ch }

type env struct {
	t       *testing.T
	dataDir string
	sock    string
	kernel  string
	cancel  context.CancelFunc
	done    chan error
	extra   []string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	data, err := os.MkdirTemp("/tmp", "cvzd")
	if err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, dataDir: data, sock: filepath.Join(data, "vzd.sock")}
	e.kernel = filepath.Join(data, "images", "img", "Image")
	os.MkdirAll(filepath.Dir(e.kernel), 0o755)
	img := make([]byte, 4096)
	binary.LittleEndian.PutUint32(img[0x38:], 0x644d5241)
	os.WriteFile(e.kernel, img, 0o644)
	t.Cleanup(func() {
		e.stopDaemon()
		e.killAll()
		os.RemoveAll(data)
	})
	return e
}

// killAll SIGKILLs any helper still running from this test's data dir.
func (e *env) killAll() {
	matches, _ := filepath.Glob(filepath.Join(e.dataDir, "vms", "*", "vz.pid"))
	for _, m := range matches {
		b, _ := os.ReadFile(m)
		if pid, err := strconv.Atoi(string(b[:max(len(b)-1, 0)])); err == nil && pid > 0 {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}

func (e *env) addVM(id string) *config.Config {
	e.t.Helper()
	vmDir := filepath.Join(e.dataDir, "vms", id)
	os.MkdirAll(vmDir, 0o750)
	disk := filepath.Join(vmDir, "rootfs.ext4")
	os.WriteFile(disk, make([]byte, 1<<20), 0o640)
	cfg := &config.Config{
		VMID: id, VCPUs: 1, MemoryMiB: 512, Kernel: e.kernel, Cmdline: "console=hvc0", Disk: disk,
		ConsoleLog:  filepath.Join(vmDir, "console.log"),
		GuestSocket: filepath.Join(vmDir, "guest.sock"),
		CtlSocket:   filepath.Join(vmDir, "ctl.sock"),
		ExitedPath:  filepath.Join(vmDir, "exited.json"),
		Lease:       config.Lease{Gateway: "10.200.0.1/30", Guest: "10.200.0.2/30", MAC: "02:00:0a:c8:00:02"},
	}
	e.writeConfig(cfg)
	return cfg
}

func (e *env) writeConfig(cfg *config.Config) {
	raw, _ := json.Marshal(cfg)
	if err := os.WriteFile(filepath.Join(e.dataDir, "vms", cfg.VMID, "vz.json"), raw, 0o640); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) startDaemon() {
	e.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	e.done = make(chan error, 1)
	env := append([]string{"CREW_VZD_FAKE_HELPER=1"}, e.extra...)
	go func() {
		e.done <- Run(ctx, Options{
			SocketPath: e.sock, DataDir: e.dataDir, HelperPath: os.Args[0],
			HelperEnv: env, Limits: limits, StartTimeout: 10 * time.Second, ForceWait: time.Second,
		})
	}()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := ctlproto.Call(context.Background(), e.sock, ctlproto.Request{Op: "list"}); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	e.t.Fatal("daemon never answered")
}

func (e *env) stopDaemon() {
	if e.cancel != nil {
		e.cancel()
		select {
		case <-e.done:
		case <-time.After(5 * time.Second):
			e.t.Error("daemon did not exit")
		}
		e.cancel = nil
	}
}

func (e *env) call(req ctlproto.Request) ctlproto.Response {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	resp, err := ctlproto.Call(ctx, e.sock, req)
	if err != nil {
		e.t.Fatal(err)
	}
	return resp
}

func (e *env) start(id string) ctlproto.Response {
	return e.call(ctlproto.Request{Op: "start", VMID: id, Deadline: time.Now().Add(time.Hour).Unix()})
}

func (e *env) waitExited(id string) exitrec.Record {
	e.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		resp := e.call(ctlproto.Request{Op: "status", VMID: id})
		if resp.OK && resp.VM.State == "exited" && resp.VM.Exited != nil {
			return *resp.VM.Exited
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.t.Fatalf("%s never exited", id)
	return exitrec.Record{}
}

func TestStartStatusStop(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.startDaemon()
	resp := e.start("vm1")
	if !resp.OK || resp.VM == nil || resp.VM.PID <= 0 || resp.VM.State != "running" {
		t.Fatalf("start: %+v", resp)
	}
	pid := resp.VM.PID
	if pid == os.Getpid() {
		t.Fatal("helper is not a separate process")
	}
	st := e.call(ctlproto.Request{Op: "status", VMID: "vm1"})
	if !st.OK || st.VM.State != "running" || st.VM.PID != pid {
		t.Fatalf("status: %+v", st)
	}
	list := e.call(ctlproto.Request{Op: "list"})
	if !list.OK || len(list.VMs) != 1 || list.VMs[0].VMID != "vm1" {
		t.Fatalf("list: %+v", list)
	}
	if resp := e.call(ctlproto.Request{Op: "stop", VMID: "vm1"}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	rec := e.waitExited("vm1")
	if rec.Code != 0 {
		t.Fatalf("exited %+v", rec)
	}
	if list := e.call(ctlproto.Request{Op: "list"}); len(list.VMs) != 0 {
		t.Fatalf("list after exit: %+v", list)
	}
	// The helper's own session: it doesn't share the daemon's.
	if sid, _ := getsid(pid); sid == mySid() {
		t.Fatal("helper shares the daemon's session")
	}
}

func TestForceStop(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.startDaemon()
	e.start("vm1")
	if resp := e.call(ctlproto.Request{Op: "stop", VMID: "vm1", Force: true}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	if rec := e.waitExited("vm1"); rec.Code != 2 || rec.Reason != exitrec.ReasonKilled {
		t.Fatalf("exited %+v", rec)
	}
}

func TestForceStopWedgedHelper(t *testing.T) {
	e := newEnv(t)
	e.extra = []string{"CREW_VZD_FAKE_HANG=1"}
	e.addVM("vm1")
	e.startDaemon()
	pid := e.start("vm1").VM.PID
	start := time.Now()
	if resp := e.call(ctlproto.Request{Op: "stop", VMID: "vm1", Force: true}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	rec := e.waitExited("vm1")
	if rec.Code != 2 || rec.Reason != exitrec.ReasonKilled {
		t.Fatalf("exited %+v", rec)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("force stop took %v", time.Since(start))
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("helper %d still alive: %v", pid, err)
	}
}

func TestRefusals(t *testing.T) {
	e := newEnv(t)
	cfg := e.addVM("vm1")
	e.startDaemon()
	future := time.Now().Add(time.Hour).Unix()
	cases := []struct {
		name string
		req  ctlproto.Request
		code string
	}{
		{"no vm id", ctlproto.Request{Op: "start", Deadline: future}, ctlproto.ErrBadRequest},
		{"path vm id", ctlproto.Request{Op: "start", VMID: "../vm1", Deadline: future}, ctlproto.ErrBadRequest},
		{"unknown vm", ctlproto.Request{Op: "start", VMID: "vm9", Deadline: future}, ctlproto.ErrNotFound},
		{"no deadline", ctlproto.Request{Op: "start", VMID: "vm1"}, ctlproto.ErrBadRequest},
		{"past deadline", ctlproto.Request{Op: "start", VMID: "vm1", Deadline: time.Now().Add(-time.Minute).Unix()}, ctlproto.ErrBadRequest},
		{"far deadline", ctlproto.Request{Op: "start", VMID: "vm1", Deadline: time.Now().Add(30 * 24 * time.Hour).Unix()}, ctlproto.ErrBadRequest},
		{"unknown op", ctlproto.Request{Op: "reboot", VMID: "vm1"}, ctlproto.ErrUnknownOp},
		{"stop unknown", ctlproto.Request{Op: "stop", VMID: "vm9"}, ctlproto.ErrNotFound},
		{"status unknown", ctlproto.Request{Op: "status", VMID: "vm9"}, ctlproto.ErrNotFound},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := e.call(tc.req)
			if resp.OK || resp.Error != tc.code {
				t.Fatalf("got %+v, want error %s", resp, tc.code)
			}
		})
	}

	t.Run("config out of limits", func(t *testing.T) {
		cfg.VCPUs = 16
		e.writeConfig(cfg)
		defer func() { cfg.VCPUs = 1; e.writeConfig(cfg) }()
		if resp := e.start("vm1"); resp.OK || resp.Error != ctlproto.ErrInvalidConfig {
			t.Fatalf("got %+v", resp)
		}
	})
	t.Run("config path outside data dir", func(t *testing.T) {
		old := cfg.Kernel
		cfg.Kernel = "/System/Library/Kernels/kernel"
		e.writeConfig(cfg)
		defer func() { cfg.Kernel = old; e.writeConfig(cfg) }()
		if resp := e.start("vm1"); resp.OK || resp.Error != ctlproto.ErrInvalidConfig {
			t.Fatalf("got %+v", resp)
		}
	})
	t.Run("vm_id mismatch", func(t *testing.T) {
		other := e.addVM("vm2")
		other.VMID = "vm1"
		raw, _ := json.Marshal(other)
		os.WriteFile(filepath.Join(e.dataDir, "vms", "vm2", "vz.json"), raw, 0o640)
		if resp := e.start("vm2"); resp.OK || resp.Error != ctlproto.ErrInvalidConfig {
			t.Fatalf("got %+v", resp)
		}
	})
}

func TestNoRelaunch(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.addVM("vm2")
	e.startDaemon()
	if resp := e.start("vm1"); !resp.OK {
		t.Fatal(resp)
	}
	if resp := e.start("vm1"); resp.OK || resp.Error != ctlproto.ErrAlreadyRunning {
		t.Fatalf("second start: %+v", resp)
	}
	e.call(ctlproto.Request{Op: "stop", VMID: "vm1", Force: true})
	e.waitExited("vm1")
	if resp := e.start("vm1"); resp.OK || resp.Error != ctlproto.ErrAlreadyExited {
		t.Fatalf("start after exit: %+v", resp)
	}
	// A helper that died before writing exited.json leaves vz.pid behind.
	os.WriteFile(filepath.Join(e.dataDir, "vms", "vm2", helper.PIDFile), []byte("1\n"), 0o640)
	if resp := e.start("vm2"); resp.OK || resp.Error != ctlproto.ErrAlreadyLaunched {
		t.Fatalf("start after crash: %+v", resp)
	}
}

func TestReadoptAfterDaemonRestart(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.addVM("vm2")
	e.startDaemon()
	pid1 := e.start("vm1").VM.PID
	pid2 := e.start("vm2").VM.PID
	e.stopDaemon()
	// Helpers outlive the daemon.
	for _, pid := range []int{pid1, pid2} {
		if err := syscall.Kill(pid, 0); err != nil {
			t.Fatalf("helper %d died with the daemon: %v", pid, err)
		}
	}
	e.startDaemon()
	list := e.call(ctlproto.Request{Op: "list"})
	if !list.OK || len(list.VMs) != 2 {
		t.Fatalf("list after restart: %+v", list)
	}
	if resp := e.start("vm1"); resp.OK || resp.Error != ctlproto.ErrAlreadyRunning {
		t.Fatalf("adopted VM restarted: %+v", resp)
	}
	e.call(ctlproto.Request{Op: "stop", VMID: "vm1"})
	if rec := e.waitExited("vm1"); rec.Code != 0 {
		t.Fatalf("vm1 %+v", rec)
	}
	// An adopted helper that is killed outright gets a record from the daemon.
	syscall.Kill(pid2, syscall.SIGKILL)
	rec := e.waitExited("vm2")
	if rec.Reason != exitrec.ReasonHelperDied || rec.Code != 1 {
		t.Fatalf("vm2 %+v", rec)
	}
	if list := e.call(ctlproto.Request{Op: "list"}); len(list.VMs) != 0 {
		t.Fatalf("list: %+v", list)
	}
}

func TestChildKilledExternally(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.startDaemon()
	pid := e.start("vm1").VM.PID
	syscall.Kill(pid, syscall.SIGKILL)
	rec := e.waitExited("vm1")
	if rec.Reason != exitrec.ReasonHelperDied {
		t.Fatalf("exited %+v", rec)
	}
}

func TestSocketMode(t *testing.T) {
	e := newEnv(t)
	e.startDaemon()
	st, err := os.Stat(e.sock)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o660 {
		t.Fatalf("vzd.sock mode %v, want 0660", st.Mode().Perm())
	}
}

func TestStatusOfNeverStarted(t *testing.T) {
	e := newEnv(t)
	e.addVM("vm1")
	e.startDaemon()
	resp := e.call(ctlproto.Request{Op: "status", VMID: "vm1"})
	if !resp.OK || resp.VM.State != "not_started" {
		t.Fatalf("status: %+v", resp)
	}
}
