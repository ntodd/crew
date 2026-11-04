package vmctl

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// fakeSys records what the server asks of the host.
type fakeSys struct {
	cmds    [][]string
	stdins  []string
	answer  func(argv []string) (string, error)
	agent   map[string][]byte // "vm_id/name"
	root    map[string][]byte
	wrote   map[string]string
	created map[string]string
	exists  map[string]bool
	globs   map[string][]string
	jails   []Jail
	removed []string
	ref     ruleset.Listing
}

func newFake() *fakeSys {
	return &fakeSys{agent: map[string][]byte{}, wrote: map[string]string{},
		created: map[string]string{}, exists: map[string]bool{}, globs: map[string][]string{},
		// A Flatcar box's accounts, none in the VM range.
		root: map[string][]byte{
			"/etc/passwd":                  []byte("root:x:0:0:root:/root:/bin/bash\ncore:x:500:500::/home/core:/bin/bash\n"),
			"/etc/group":                   []byte("root:x:0:\ncore:x:500:\n_crewagent:x:900:\n"),
			"/usr/share/baselayout/passwd": []byte("nobody:x:65534:65534::/:/sbin/nologin\n"),
			"/usr/share/baselayout/group":  []byte("nobody:x:65534:\n"),
			"/etc/subuid":                  []byte(""),
			"/etc/subgid":                  []byte(""),
		}}
}

func TestVMIDsMustBeNobodys(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	// Lease 3: uid and gid 200003.
	for name, f := range map[string]func(root map[string][]byte){
		"a user has the uid": func(r map[string][]byte) {
			r["/etc/passwd"] = append(r["/etc/passwd"], "build:x:200003:500::/:/bin/sh\n"...)
		},
		"a user's primary group is the gid": func(r map[string][]byte) {
			r["/etc/passwd"] = append(r["/etc/passwd"], "build:x:1000:200003::/:/bin/sh\n"...)
		},
		"a group has the gid": func(r map[string][]byte) {
			r["/etc/group"] = append(r["/etc/group"], "docker2:x:200003:\n"...)
		},
		"Flatcar's own users":  func(r map[string][]byte) { r["/usr/share/baselayout/passwd"] = []byte("x:x:200003:1::/:/bin/sh\n") },
		"Flatcar's own groups": func(r map[string][]byte) { r["/usr/share/baselayout/group"] = []byte("x:x:200003:\n") },
		"a subuid range":       func(r map[string][]byte) { r["/etc/subuid"] = []byte("core:200000:65536\n") },
		"a subgid range":       func(r map[string][]byte) { r["/etc/subgid"] = []byte("core:199999:5\n") },
		"no passwd to check":   func(r map[string][]byte) { delete(r, "/etc/passwd") },
		"no group to check":    func(r map[string][]byte) { delete(r, "/etc/group") },
	} {
		for _, verb := range []string{`{"verb":"start","vm_id":"` + vmID + `"}`, `{"verb":"tap-add","lease_index":3}`} {
			sys := newFake()
			sys.agent[vmID+"/vm.json"] = vmJSON(now.Unix() + 3600)
			sys.agent[vmID+"/fc.json"] = encode(t, agentFC())
			sys.answer = showing("")
			f(sys.root)
			r := handle(t, server(t, sys, now), verb)
			if r.OK || r.Error != ErrIDInUse {
				t.Errorf("%s, %s: %+v", name, verb, r)
			}
			if len(sys.jails) != 0 || sys.ran("ip") || sys.ran("systemd-run") {
				t.Errorf("%s, %s: went ahead: %q", name, verb, sys.cmds)
			}
		}
	}

	// Ranges that end before the uid, and lines that aren't entries, are fine.
	sys := newFake()
	sys.root["/etc/subuid"] = []byte("core:100000:65536\n# a comment\n\nbad line\n")
	sys.root["/etc/subgid"] = []byte("core:100000:100003\n")
	if r := handle(t, server(t, sys, now), `{"verb":"tap-add","lease_index":3}`); !r.OK {
		t.Fatalf("%+v", r)
	}
}

func (f *fakeSys) Run(_ context.Context, stdin []byte, argv ...string) ([]byte, error) {
	f.cmds = append(f.cmds, argv)
	f.stdins = append(f.stdins, string(stdin))
	if f.answer != nil {
		out, err := f.answer(argv)
		return []byte(out), err
	}
	return nil, nil
}

func (f *fakeSys) ReadAgentFile(id, name string) ([]byte, error) {
	if b, ok := f.agent[id+"/"+name]; ok {
		return b, nil
	}
	return nil, os.ErrNotExist
}

func (f *fakeSys) ReadFile(path string, _ int64) ([]byte, error) {
	if b, ok := f.root[path]; ok {
		return b, nil
	}
	return nil, os.ErrNotExist
}

func (f *fakeSys) WriteFile(path string, data []byte) error {
	f.wrote[path] = string(data)
	f.root[path] = data
	return nil
}

func (f *fakeSys) WriteState(name string, data []byte) error {
	return f.WriteFile(paths.State(name), data)
}

func (f *fakeSys) CreateFile(path string, data []byte) error {
	if _, ok := f.created[path]; ok {
		return os.ErrExist
	}
	f.created[path] = string(data)
	return nil
}

func (f *fakeSys) Exists(path string) bool            { return f.exists[path] }
func (f *fakeSys) Glob(pattern string) []string       { return f.globs[pattern] }
func (f *fakeSys) PrepareJail(j Jail) error           { f.jails = append(f.jails, j); return nil }
func (f *fakeSys) RemoveJail(id string, _ Peer) error { f.removed = append(f.removed, id); return nil }
func (f *fakeSys) Reference(uplink string) (ruleset.Listing, error) {
	if uplink != "eth0" {
		return ruleset.Listing{}, fmt.Errorf("uplink %s", uplink)
	}
	return f.ref, nil
}

func (f *fakeSys) ran(prefix ...string) bool {
	for _, c := range f.cmds {
		if len(c) >= len(prefix) && reflect.DeepEqual(c[:len(prefix)], prefix) {
			return true
		}
	}
	return false
}

var agentPeer = Peer{UID: 500, GID: 500}

func server(t *testing.T, sys *fakeSys, now time.Time) *Server {
	t.Helper()
	return &Server{Paths: paths, Net: testNet(t), Sys: sys, Now: func() time.Time { return now }, Version: "test"}
}

func req(t *testing.T, line string) Request {
	t.Helper()
	r, err := ParseRequest([]byte(line), testNet(t))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func handle(t *testing.T, s *Server, line string) Response {
	t.Helper()
	return s.Handle(context.Background(), req(t, line), agentPeer)
}

func showing(state string) func(argv []string) (string, error) {
	return func(argv []string) (string, error) {
		if argv[0] == "systemctl" && argv[1] == "show" {
			if state == "" {
				return "LoadState=not-found\nActiveState=inactive\nSubState=dead\nMainPID=0\n", nil
			}
			return "LoadState=loaded\nActiveState=" + state + "\nSubState=running\nMainPID=4242\n", nil
		}
		return "", nil
	}
}

func TestStart(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	box := newBox(t)
	sys := box.fakeSys
	sys.agent[vmID+"/vm.json"] = vmJSON(now.Unix() + 3600)
	sys.agent[vmID+"/fc.json"] = encode(t, agentFC())
	s := server(t, sys, now)

	resp := handle(t, s, `{"verb":"start","vm_id":"`+vmID+`"}`)
	if !resp.OK {
		t.Fatalf("%+v", resp)
	}
	if len(sys.jails) != 1 {
		t.Fatalf("jails: %+v", sys.jails)
	}
	j := sys.jails[0]
	want, _ := ChrootConfig(encode(t, agentFC()), j.VM, paths)
	if j.VM.ID != vmID || j.VM.Lease.Index != 3 || string(j.Config) != string(want) || j.Owner != agentPeer {
		t.Fatalf("jail: %+v", j)
	}
	vm, _ := ParseVM(vmJSON(now.Unix()+3600), vmID, testNet(t), now)
	if !sys.ran(SystemdRunArgv(vm, paths, now)...) {
		t.Fatalf("commands: %q", sys.cmds)
	}
	// It checked the packet filter itself first.
	if !sys.ran("nft", "-j", "list", "table", "inet", "crew") || !sys.ran("nft", "-j", "list", "set", "inet", "crew", "site4") {
		t.Fatalf("commands: %q", sys.cmds)
	}
}

// crew-vmctl doesn't count on the agent having noticed (§14.2): every
// start checks the ruleset and site4 itself.
func TestStartRefusesWithoutAVerifiedFilter(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	setup := func(b *testBox) *fakeSys {
		b.agent[vmID+"/vm.json"] = vmJSON(now.Unix() + 3600)
		b.agent[vmID+"/fc.json"] = encode(t, agentFC())
		return b.fakeSys
	}

	flushed := newBox(t)
	flushed.table = `{"nftables":[{"metainfo":{}}]}`
	r := handle(t, server(t, setup(flushed), now), `{"verb":"start","vm_id":"`+vmID+`"}`)
	if r.OK || r.Error != ErrNftMismatch || len(flushed.jails) != 0 || flushed.ran("systemd-run") {
		t.Fatalf("a flushed ruleset: %+v", r)
	}

	// site4 that's short is refilled, and the start goes ahead.
	short := newBox(t)
	short.site4 = []string{"198.51.100.20/32"}
	inner := short.answer
	short.answer = func(argv []string) (string, error) {
		if strings.Join(argv, " ") == "nft -f -" {
			short.site4 = []string{"192.168.64.0/24", "198.51.100.20/32"}
		}
		return inner(argv)
	}
	if r := handle(t, server(t, setup(short), now), `{"verb":"start","vm_id":"`+vmID+`"}`); !r.OK {
		t.Fatalf("a short site4, refilled: %+v", r)
	}
	if !short.ran("nft", "-f", "-") {
		t.Fatal("site4 wasn't refilled")
	}

	// One that stays short is refused.
	stuck := newBox(t)
	stuck.site4 = nil
	r = handle(t, server(t, setup(stuck), now), `{"verb":"start","vm_id":"`+vmID+`"}`)
	if r.OK || r.Error != ErrSite4NotReady || len(stuck.jails) != 0 || stuck.ran("systemd-run") {
		t.Fatalf("site4 that won't fill: %+v", r)
	}
}

func TestStartRefusesBadFilesBeforeTouchingAnything(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	sys := newFake()
	sys.agent[vmID+"/vm.json"] = vmJSON(now.Unix() + 3600)
	fc := agentFC()
	drv(fc)["path_on_host"] = "/etc/shadow"
	sys.agent[vmID+"/fc.json"] = encode(t, fc)
	resp := handle(t, server(t, sys, now), `{"verb":"start","vm_id":"`+vmID+`"}`)
	if resp.OK || resp.Error != ErrInvalidConfig || len(sys.jails) != 0 || len(sys.cmds) != 0 {
		t.Fatalf("%+v, cmds %q", resp, sys.cmds)
	}

	missing := newFake()
	resp = handle(t, server(t, missing, now), `{"verb":"start","vm_id":"`+vmID+`"}`)
	if resp.OK || resp.Error != ErrInvalidConfig {
		t.Fatalf("no vm.json: %+v", resp)
	}
}

func TestStartIsOnce(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	sys := newFake()
	sys.agent[vmID+"/vm.json"] = vmJSON(now.Unix() + 3600)
	sys.agent[vmID+"/fc.json"] = encode(t, agentFC())
	sys.answer = showing("active")
	resp := handle(t, server(t, sys, now), `{"verb":"start","vm_id":"`+vmID+`"}`)
	if resp.OK || resp.Error != ErrAlreadyLaunch || len(sys.jails) != 0 {
		t.Fatalf("%+v", resp)
	}
}

func TestStop(t *testing.T) {
	sys := newFake()
	sys.answer = showing("active")
	s := server(t, sys, time.Now())
	if r := handle(t, s, `{"verb":"stop","vm_id":"`+vmID+`","force":true}`); !r.OK {
		t.Fatal(r)
	}
	if !sys.ran("systemctl", "kill", "--kill-whom=main", "--signal=SIGKILL", Unit(vmID)) {
		t.Fatalf("%q", sys.cmds)
	}
	if r := handle(t, s, `{"verb":"stop","vm_id":"`+vmID+`"}`); !r.OK {
		t.Fatal(r)
	}
	if !sys.ran("systemctl", "stop", "--no-block", Unit(vmID)) {
		t.Fatalf("%q", sys.cmds)
	}

	gone := newFake()
	gone.answer = showing("")
	if r := handle(t, server(t, gone, time.Now()), `{"verb":"stop","vm_id":"`+vmID+`","force":true}`); r.OK || r.Error != ErrNotFound {
		t.Fatalf("%+v", r)
	}
}

func TestStatus(t *testing.T) {
	sys := newFake()
	sys.answer = showing("active")
	r := handle(t, server(t, sys, time.Now()), `{"verb":"status","vm_id":"`+vmID+`"}`)
	if !r.OK || r.VM == nil || r.VM.State != "active" || r.VM.PID != 4242 || r.VM.Exited != nil {
		t.Fatalf("%+v", r.VM)
	}

	dead := newFake()
	dead.answer = showing("")
	dead.root[paths.Exited(vmID)] = []byte(`{"service_result":"timeout","exit_code":"killed","exit_status":"TERM","code":143,"at":5}`)
	r = handle(t, server(t, dead, time.Now()), `{"verb":"status","vm_id":"`+vmID+`"}`)
	if !r.OK || r.VM.State != "gone" || r.VM.Exited == nil || r.VM.Exited.ServiceResult != "timeout" || r.VM.Exited.Code != 143 {
		t.Fatalf("%+v %+v", r.VM, r.VM.Exited)
	}
}

func TestList(t *testing.T) {
	sys := newFake()
	sys.answer = func(argv []string) (string, error) {
		return "crew-vm-" + vmID + ".service loaded active running crew-vm\n" +
			"crew-vm-not-a-uuid.service loaded active running x\n" +
			"crew-vm-0195f3a2-7c4e-7b1a-9f00-0123456789ac.service loaded failed failed y\n", nil
	}
	r := handle(t, server(t, sys, time.Now()), `{"verb":"list"}`)
	if !r.OK || !reflect.DeepEqual(r.VMs, []string{vmID, "0195f3a2-7c4e-7b1a-9f00-0123456789ac"}) {
		t.Fatalf("%+v", r)
	}
	if !sys.ran("systemctl", "list-units", "--all", "--plain", "--no-legend", "--no-pager", "--type=service", "crew-vm-*") {
		t.Fatalf("%q", sys.cmds)
	}

	// And the jails it holds, unit or not, so the agent can find any it
	// has no record of.
	dir := paths.JailDir("x")[:len(paths.JailDir("x"))-1]
	sys.globs[dir+"*"] = []string{dir + vmID, dir + "0195f3a2-0000-7000-8000-00000000dead", dir + "not-a-uuid"}
	r = handle(t, server(t, sys, time.Now()), `{"verb":"list"}`)
	if !reflect.DeepEqual(r.Jails, []string{vmID, "0195f3a2-0000-7000-8000-00000000dead"}) {
		t.Fatalf("%+v", r)
	}
}

func TestTaps(t *testing.T) {
	sys := newFake()
	s := server(t, sys, time.Now())
	if r := handle(t, s, `{"verb":"tap-add","lease_index":3}`); !r.OK {
		t.Fatal(r)
	}
	want := [][]string{
		{"ip", "tuntap", "add", "dev", "crewt3", "mode", "tap", "user", "200003", "group", "200003"},
		{"ip", "addr", "add", "10.200.0.13/30", "dev", "crewt3"},
		{"ip", "link", "set", "dev", "crewt3", "up"},
	}
	if !reflect.DeepEqual(sys.cmds, want) {
		t.Fatalf("%q", sys.cmds)
	}
	// IPv6 off and strict reverse-path filtering, before the link is up.
	if sys.wrote["/proc/sys/net/ipv6/conf/crewt3/disable_ipv6"] != "1" ||
		sys.wrote["/proc/sys/net/ipv4/conf/crewt3/rp_filter"] != "1" {
		t.Fatalf("%v", sys.wrote)
	}

	// A tap left over from a VM that's gone is made again.
	again := newFake()
	again.exists["/sys/class/net/crewt3"] = true
	if r := handle(t, server(t, again, time.Now()), `{"verb":"tap-add","lease_index":3}`); !r.OK {
		t.Fatal(r)
	}
	if !reflect.DeepEqual(again.cmds[0], []string{"ip", "link", "del", "dev", "crewt3"}) {
		t.Fatalf("%q", again.cmds)
	}

	del := newFake()
	del.exists["/sys/class/net/crewt3"] = true
	if r := handle(t, server(t, del, time.Now()), `{"verb":"tap-del","lease_index":3}`); !r.OK {
		t.Fatal(r)
	}
	if !reflect.DeepEqual(del.cmds, [][]string{{"ip", "link", "del", "dev", "crewt3"}}) {
		t.Fatalf("%q", del.cmds)
	}
	none := newFake()
	if r := handle(t, server(t, none, time.Now()), `{"verb":"tap-del","lease_index":3}`); !r.OK || len(none.cmds) != 0 {
		t.Fatalf("%+v %q", r, none.cmds)
	}
}

func TestPairs(t *testing.T) {
	sys := newFake()
	s := server(t, sys, time.Now())
	if r := handle(t, s, `{"verb":"pair-add","lease_index":3}`); !r.OK {
		t.Fatal(r)
	}
	if r := handle(t, s, `{"verb":"pair-del","lease_index":3}`); !r.OK {
		t.Fatal(r)
	}
	want := [][]string{
		{"nft", "add", "element", "inet", "crew", "vm_pairs", "{ crewt3 . 10.200.0.14 }"},
		{"nft", "delete", "element", "inet", "crew", "vm_pairs", "{ crewt3 . 10.200.0.14 }"},
	}
	if !reflect.DeepEqual(sys.cmds, want) {
		t.Fatalf("%q", sys.cmds)
	}

	missing := newFake()
	missing.answer = func([]string) (string, error) {
		return "", errors.New("Error: Could not process rule: No such file or directory")
	}
	if r := handle(t, server(t, missing, time.Now()), `{"verb":"pair-del","lease_index":3}`); !r.OK {
		t.Fatalf("a pair that's gone is deleted: %+v", r)
	}
	if r := handle(t, server(t, missing, time.Now()), `{"verb":"pair-add","lease_index":3}`); r.OK {
		t.Fatal("a pair that can't be added is an error (the start is aborted, §11.2)")
	}
}

func TestReboot(t *testing.T) {
	boot := "0195f3a2-0000-7000-8000-0000000000b0"
	other := `{"verb":"reboot","boot_id":"0195f3a2-0000-7000-8000-0000000000b1"}`

	sys := newFake()
	sys.root["/proc/sys/kernel/random/boot_id"] = []byte(boot + "\n")
	r := handle(t, server(t, sys, time.Now()), other)
	if !r.OK || !r.Already || len(sys.cmds) != 0 {
		t.Fatalf("another boot: %+v %q", r, sys.cmds)
	}

	busy := newFake()
	busy.root["/proc/sys/kernel/random/boot_id"] = []byte(boot + "\n")
	busy.answer = func(argv []string) (string, error) {
		if argv[1] == "list-units" {
			return "crew-vm-" + vmID + ".service loaded active running x\n", nil
		}
		return "", nil
	}
	r = handle(t, server(t, busy, time.Now()), `{"verb":"reboot","boot_id":"`+boot+`"}`)
	if r.OK || r.Error != ErrBusy {
		t.Fatalf("busy: %+v", r)
	}
	r = handle(t, server(t, busy, time.Now()), `{"verb":"reboot","boot_id":"`+boot+`","force":true}`)
	if !r.OK || !busy.ran("systemd-run", "--on-active=5", "systemctl", "reboot") {
		t.Fatalf("forced: %+v %q", r, busy.cmds)
	}
}

func TestCleanup(t *testing.T) {
	sys := newFake()
	killed := false
	sys.answer = func(argv []string) (string, error) {
		if argv[1] == "kill" {
			killed = true
		}
		if killed {
			return showing("")(argv)
		}
		return showing("active")(argv)
	}
	sys.root[paths.JailDir(vmID)+"/lease"] = []byte("3\n")
	r := handle(t, server(t, sys, time.Now()), `{"verb":"cleanup","vm_id":"`+vmID+`"}`)
	if !r.OK {
		t.Fatal(r)
	}
	for _, c := range [][]string{
		{"systemctl", "kill", "--kill-whom=main", "--signal=SIGKILL", Unit(vmID)},
		{"nft", "delete", "element", "inet", "crew", "vm_pairs", "{ crewt3 . 10.200.0.14 }"},
	} {
		if !sys.ran(c...) {
			t.Errorf("didn't run %q: %q", c, sys.cmds)
		}
	}
	if !reflect.DeepEqual(sys.removed, []string{vmID}) {
		t.Fatalf("removed %v", sys.removed)
	}

	// Never started: nothing to kill, no lease, nothing in the way.
	never := newFake()
	never.answer = showing("")
	if r := handle(t, server(t, never, time.Now()), `{"verb":"cleanup","vm_id":"`+vmID+`"}`); !r.OK {
		t.Fatal(r)
	}
	if never.ran("systemctl", "kill") || never.ran("nft") {
		t.Fatalf("%q", never.cmds)
	}
}

func TestNftVerify(t *testing.T) {
	sys := newBox(t)
	if r := handle(t, server(t, sys.fakeSys, time.Now()), `{"verb":"nft-verify"}`); !r.OK {
		t.Fatalf("%+v", r)
	}
	if !sys.ran("nft", "-j", "list", "table", "inet", "crew") || !sys.ran("iptables-nft-save", "-t", "mangle") {
		t.Fatalf("%q", sys.cmds)
	}

	tampered := newBox(t)
	tampered.table = strings.Replace(tampered.table, `"policy": "drop"`, `"policy": "accept"`, 1)
	r := handle(t, server(t, tampered.fakeSys, time.Now()), `{"verb":"nft-verify"}`)
	if r.OK || r.Error != ErrNftMismatch || !strings.Contains(r.Detail, "chain forward") {
		t.Fatalf("%+v", r)
	}

	unloaded := newFake()
	if r := handle(t, server(t, unloaded, time.Now()), `{"verb":"nft-verify"}`); r.OK || r.Error != ErrNftMismatch {
		t.Fatalf("crew-net never ran: %+v", r)
	}
}

func TestRestartCacheAndInfo(t *testing.T) {
	sys := newFake()
	sys.answer = func(argv []string) (string, error) {
		switch argv[0] {
		case paths.Firecracker():
			return "Firecracker v1.17.0\n\nsome more\n", nil
		case "systemctl":
			return "systemd 260 (260.4)\n+PAM +AUDIT\n", nil
		}
		return "", nil
	}
	s := server(t, sys, time.Now())
	if r := handle(t, s, `{"verb":"restart-cache"}`); !r.OK || !sys.ran("systemctl", "restart", "--no-block", "crew-cache.service") {
		t.Fatalf("%+v %q", r, sys.cmds)
	}
	r := handle(t, s, `{"verb":"info"}`)
	if !r.OK || r.Info == nil || *r.Info != (Info{Vmctl: "test", Firecracker: "1.17.0", Systemd: 260}) {
		t.Fatalf("%+v %+v", r, r.Info)
	}
}

func TestExitRecord(t *testing.T) {
	for _, tc := range []struct {
		result, code, status string
		want                 int
	}{
		{"success", "exited", "0", 0},
		{"exit-code", "exited", "1", 1},
		{"signal", "killed", "KILL", 137},
		{"timeout", "killed", "TERM", 143},
		{"oom-kill", "killed", "KILL", 137},
	} {
		rec, err := NewExitRecord(tc.result, tc.code, tc.status, time.Unix(5, 0))
		if err != nil || rec.Code != tc.want || rec.ServiceResult != tc.result || rec.At != 5 {
			t.Errorf("%+v: %+v %v", tc, rec, err)
		}
	}
	for _, bad := range [][3]string{{"", "exited", "0"}, {"success\n", "exited", "0"}, {"success", "exited", "x; rm"},
		{"success", "weird", "0"}, {strings.Repeat("a", 65), "exited", "0"}} {
		if _, err := NewExitRecord(bad[0], bad[1], bad[2], time.Now()); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
}

func TestSite4(t *testing.T) {
	sys := newFake()
	sys.answer = func(argv []string) (string, error) {
		if reflect.DeepEqual(argv, []string{"ip", "-j", "-4", "addr", "show", "dev", "eth0"}) {
			return `[{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.168.64.34","prefixlen":24},
				{"family":"inet","local":"203.0.113.9","prefixlen":32}]}]`, nil
		}
		return "", nil
	}
	sys.root["/run/crew/uplink"] = []byte("eth0\n")
	sys.root[paths.Egress()] = []byte("198.51.100.20\n")
	sys.root[paths.State("egress4")] = []byte("198.51.100.20\n")
	sys.root[ExtraBlockedFile] = []byte("192.168.64.0/26, 8.8.8.0/24,not-a-cidr\n")
	s := server(t, sys, time.Now())
	set, err := s.Site4(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	// The uplink's subnets, the egress address and the admin's list; one
	// inside another is left out (nft refuses overlapping intervals), and
	// what doesn't parse is dropped.
	if want := []string{"8.8.8.0/24", "192.168.64.0/24", "198.51.100.20/32", "203.0.113.9/32"}; !reflect.DeepEqual(set, want) {
		t.Fatalf("site4 %v", set)
	}
	if err := s.RefreshSite4(context.Background()); err != nil {
		t.Fatal(err)
	}
	last := sys.stdins[len(sys.stdins)-1]
	want := "flush set inet crew site4\nadd element inet crew site4 { 8.8.8.0/24, 192.168.64.0/24, 198.51.100.20/32, 203.0.113.9/32 }\n"
	if last != want || !reflect.DeepEqual(sys.cmds[len(sys.cmds)-1], []string{"nft", "-f", "-"}) {
		t.Fatalf("%q", last)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
