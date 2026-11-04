package vmctl

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ntodd/crew/native/crew-vmctl/etc"
	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// Peer is the connecting process (SO_PEERCRED): the agent.
type Peer struct{ UID, GID int }

// Jail is what start asks the host to lay out before the unit runs.
type Jail struct {
	VM     VM
	Config []byte // the chroot's fc.json
	Owner  Peer   // who the clone and kernel must belong to, and who gets the console
}

// Sys is everything crew-vmctl does to the host, so the verbs' logic
// can be tested anywhere. The Linux implementation is host_linux.go.
type Sys interface {
	// Run runs argv with a fixed PATH and no other environment, and
	// returns its stdout; a failure's error carries its stderr.
	Run(ctx context.Context, stdin []byte, argv ...string) ([]byte, error)
	// ReadAgentFile reads vms/<vm_id>/<name>, at most MaxFile bytes,
	// never through a symlink.
	ReadAgentFile(vmID, name string) ([]byte, error)
	// ReadFile, WriteFile and CreateFile (exclusive) are for files only
	// root writes: /proc, /run/crew, the jail. ReadFile also reads the
	// agent's env and egress files, never through a symlink.
	ReadFile(path string, max int64) ([]byte, error)
	WriteFile(path string, data []byte) error
	CreateFile(path string, data []byte) error
	Exists(path string) bool
	Glob(pattern string) []string
	// PrepareJail lays out the VM's jail directory (README.md); it fails
	// with ErrAlreadyLaunch if the directory exists.
	PrepareJail(j Jail) error
	// RemoveJail moves the console and logs into vms/<vm_id>/ and removes
	// the VM's jail directory. Idempotent.
	RemoveJail(vmID string, owner Peer) error
	// Reference loads etc/ into a fresh network namespace and lists it.
	Reference(uplink string) (ruleset.Listing, error)
}

// Server answers requests.
type Server struct {
	Paths   Paths
	Net     VMNet
	Sys     Sys
	Now     func() time.Time
	Version string
}

// Response is the one line written back.
type Response struct {
	OK      bool         `json:"ok"`
	Error   string       `json:"error,omitempty"`
	Detail  string       `json:"detail,omitempty"`
	VM      *VMStatus    `json:"vm,omitempty"`
	VMs     []string     `json:"vms,omitempty"`
	Already bool         `json:"already,omitempty"`
	Info    *Info        `json:"info,omitempty"`
	Site4   *Site4Status `json:"site4,omitempty"`
}

// VMStatus is a VM's unit, and how it ended once it has.
type VMStatus struct {
	VMID     string      `json:"vm_id"`
	State    string      `json:"state"` // systemd's ActiveState, or "gone"
	SubState string      `json:"sub_state,omitempty"`
	PID      int         `json:"pid,omitempty"`
	Exited   *ExitRecord `json:"exited,omitempty"`
}

// Info is what the agent reports as driver_version and checks against
// §11.3's requirements.
type Info struct {
	Vmctl       string `json:"vmctl"`
	Firecracker string `json:"firecracker"`
	Systemd     int    `json:"systemd"`
}

const (
	uplinkFile = "/run/crew/uplink"
	bootIDFile = "/proc/sys/kernel/random/boot_id"
	cacheUnit  = "crew-cache.service"
)

// Handle runs one checked request.
func (s *Server) Handle(ctx context.Context, r Request, peer Peer) Response {
	resp, err := s.handle(ctx, r, peer)
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			return Response{Error: e.Code, Detail: e.Detail}
		}
		return Response{Error: ErrFailed, Detail: err.Error()}
	}
	resp.OK = true
	return resp
}

func (s *Server) handle(ctx context.Context, r Request, peer Peer) (Response, error) {
	switch r.Verb {
	case "start":
		return s.start(ctx, r.VMID, peer)
	case "stop":
		return Response{}, s.stop(ctx, r.VMID, r.IsForce())
	case "status":
		st, err := s.status(ctx, r.VMID)
		return Response{VM: st}, err
	case "list":
		ids, err := s.list(ctx, false)
		return Response{VMs: ids}, err
	case "tap-add":
		return Response{}, s.tapAdd(ctx, r.Lease)
	case "tap-del":
		return Response{}, s.tapDel(ctx, r.Lease)
	case "pair-add":
		return Response{}, s.pair(ctx, "add", r.Lease)
	case "pair-del":
		return Response{}, s.pairDel(ctx, r.Lease)
	case "nft-verify":
		st, err := s.nftVerify(ctx)
		return Response{Site4: st}, err
	case "site4":
		return Response{}, s.RefreshSite4(ctx)
	case "reboot":
		return s.reboot(ctx, r.BootID, r.IsForce())
	case "cleanup":
		return Response{}, s.cleanup(ctx, r.VMID, peer)
	case "restart-cache":
		_, err := s.Sys.Run(ctx, nil, "systemctl", "restart", "--no-block", cacheUnit)
		return Response{}, err
	case "info":
		return Response{Info: s.info(ctx)}, nil
	}
	return Response{}, fail(ErrUnknownVerb, "%q", r.Verb)
}

// -- VMs ---------------------------------------------------------------------

func (s *Server) start(ctx context.Context, vmID string, peer Peer) (Response, error) {
	vmBody, err := s.Sys.ReadAgentFile(vmID, "vm.json")
	if err != nil {
		return Response{}, fail(ErrInvalidConfig, "vm.json: %v", err)
	}
	now := s.Now()
	vm, err := ParseVM(vmBody, vmID, s.Net, now)
	if err != nil {
		return Response{}, err
	}
	fcBody, err := s.Sys.ReadAgentFile(vmID, "fc.json")
	if err != nil {
		return Response{}, fail(ErrInvalidConfig, "fc.json: %v", err)
	}
	cfg, err := ChrootConfig(fcBody, vm, s.Paths)
	if err != nil {
		return Response{}, err
	}
	if err := s.checkIDs(vm.Lease); err != nil {
		return Response{}, err
	}
	st, err := s.status(ctx, vmID)
	if err != nil {
		return Response{}, err
	}
	if st.State != "gone" && st.State != "inactive" && st.State != "failed" {
		return Response{}, fail(ErrAlreadyLaunch, "%s is %s", Unit(vmID), st.State)
	}
	if err := s.Sys.PrepareJail(Jail{VM: vm, Config: cfg, Owner: peer}); err != nil {
		return Response{}, err
	}
	if _, err := s.Sys.Run(ctx, nil, SystemdRunArgv(vm, s.Paths, now)...); err != nil {
		return Response{}, fail(ErrFailed, "systemd-run: %v", err)
	}
	st, err = s.status(ctx, vmID)
	return Response{VM: st}, err
}

func (s *Server) stop(ctx context.Context, vmID string, force bool) error {
	st, err := s.status(ctx, vmID)
	if err != nil {
		return err
	}
	if !live(st.State) {
		return fail(ErrNotFound, "%s isn't running", Unit(vmID))
	}
	if force {
		return s.kill(ctx, vmID)
	}
	_, err = s.Sys.Run(ctx, nil, "systemctl", "stop", "--no-block", Unit(vmID))
	return err
}

// kill SIGKILLs the VMM, the unit's main process (jailer exec'd it, so
// it's the only one). Not the whole cgroup: systemd kills a cgroup
// through cgroup.kill, which also takes the ExecStopPost forked into it
// moments later, and the exit record with it.
func (s *Server) kill(ctx context.Context, vmID string) error {
	_, err := s.Sys.Run(ctx, nil, "systemctl", "kill", "--kill-whom=main", "--signal=SIGKILL", Unit(vmID))
	return err
}

func live(state string) bool {
	return state == "active" || state == "activating" || state == "deactivating" || state == "reloading"
}

func (s *Server) status(ctx context.Context, vmID string) (*VMStatus, error) {
	out, err := s.Sys.Run(ctx, nil, "systemctl", "show", Unit(vmID),
		"--property=LoadState,ActiveState,SubState,MainPID")
	if err != nil {
		return nil, err
	}
	props := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			props[k] = v
		}
	}
	st := &VMStatus{VMID: vmID, State: props["ActiveState"], SubState: props["SubState"]}
	if props["LoadState"] == "not-found" || st.State == "" {
		st.State, st.SubState = "gone", ""
	}
	if pid, err := strconv.Atoi(props["MainPID"]); err == nil && pid > 0 {
		st.PID = pid
	}
	if body, err := s.Sys.ReadFile(s.Paths.Exited(vmID), 4096); err == nil {
		var rec ExitRecord
		if json.Unmarshal(body, &rec) == nil {
			st.Exited = &rec
		}
	}
	return st, nil
}

// list is the crew-vm-* units systemd knows, or only the live ones.
func (s *Server) list(ctx context.Context, liveOnly bool) ([]string, error) {
	out, err := s.Sys.Run(ctx, nil, "systemctl", "list-units", "--all", "--plain", "--no-legend",
		"--no-pager", "--type=service", "crew-vm-*")
	if err != nil {
		return nil, err
	}
	ids := []string{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(f[0], "crew-vm-"), ".service")
		if !IsUUID(id) || (liveOnly && !live(f[2])) {
			continue
		}
		ids = append(ids, id)
	}
	return ids, nil
}

func (s *Server) cleanup(ctx context.Context, vmID string, peer Peer) error {
	st, err := s.status(ctx, vmID)
	if err != nil {
		return err
	}
	if live(st.State) {
		if err := s.kill(ctx, vmID); err != nil {
			return err
		}
		if err := s.waitGone(ctx, vmID, 10*time.Second); err != nil {
			return err
		}
	}
	if st.State == "failed" {
		_, _ = s.Sys.Run(ctx, nil, "systemctl", "reset-failed", Unit(vmID))
	}
	// The lease crew-vmctl recorded when it started the VM, not the
	// agent's word for it.
	if body, err := s.Sys.ReadFile(leaseFile(s.Paths, vmID), 32); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(body))); err == nil {
			if l, err := s.Net.Lease(n); err == nil {
				if err := s.pairDel(ctx, l); err != nil {
					return err
				}
				if err := s.tapDel(ctx, l); err != nil {
					return err
				}
			}
		}
	}
	return s.Sys.RemoveJail(vmID, peer)
}

func leaseFile(p Paths, vmID string) string { return p.JailDir(vmID) + "/lease" }

func (s *Server) waitGone(ctx context.Context, vmID string, max time.Duration) error {
	deadline := time.Now().Add(max)
	for {
		st, err := s.status(ctx, vmID)
		if err != nil {
			return err
		}
		if !live(st.State) {
			return nil
		}
		if time.Now().After(deadline) {
			return fail(ErrFailed, "%s is still %s after SIGKILL", Unit(vmID), st.State)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// -- the network ---------------------------------------------------------------

func (s *Server) tapAdd(ctx context.Context, l Lease) error {
	// The tap is the VM's uid's: never someone else's.
	if err := s.checkIDs(l); err != nil {
		return err
	}
	// A tap left by a VM that's gone (a crash mid-cleanup) is made again,
	// so it's this lease's, owned by this uid.
	if err := s.tapDel(ctx, l); err != nil {
		return err
	}
	uid, gid := strconv.Itoa(l.UID), strconv.Itoa(l.GID)
	if _, err := s.Sys.Run(ctx, nil, "ip", "tuntap", "add", "dev", l.Tap, "mode", "tap", "user", uid, "group", gid); err != nil {
		return err
	}
	for path, v := range map[string]string{
		"/proc/sys/net/ipv6/conf/" + l.Tap + "/disable_ipv6": "1",
		"/proc/sys/net/ipv4/conf/" + l.Tap + "/rp_filter":    "1",
	} {
		if err := s.Sys.WriteFile(path, []byte(v)); err != nil {
			return err
		}
	}
	if _, err := s.Sys.Run(ctx, nil, "ip", "addr", "add", l.Gateway+"/30", "dev", l.Tap); err != nil {
		return err
	}
	_, err := s.Sys.Run(ctx, nil, "ip", "link", "set", "dev", l.Tap, "up")
	return err
}

func (s *Server) tapDel(ctx context.Context, l Lease) error {
	if !s.Sys.Exists("/sys/class/net/" + l.Tap) {
		return nil
	}
	_, err := s.Sys.Run(ctx, nil, "ip", "link", "del", "dev", l.Tap)
	return err
}

func (s *Server) pair(ctx context.Context, op string, l Lease) error {
	_, err := s.Sys.Run(ctx, nil, "nft", op, "element", "inet", "crew", "vm_pairs",
		"{ "+l.Tap+" . "+l.Guest+" }")
	return err
}

func (s *Server) pairDel(ctx context.Context, l Lease) error {
	if err := s.pair(ctx, "delete", l); err != nil && !strings.Contains(err.Error(), "No such file or directory") {
		return err
	}
	return nil
}

func (s *Server) uplink() (string, error) {
	body, err := s.Sys.ReadFile(uplinkFile, 64)
	if err != nil {
		return "", fail(ErrNftMismatch, "crew-net hasn't loaded the ruleset (%s: %v)", uplinkFile, err)
	}
	up := strings.TrimSpace(string(body))
	if err := ruleset.CheckUplink(up); err != nil {
		return "", fail(ErrNftMismatch, "%s: %v", uplinkFile, err)
	}
	return up, nil
}

// nftVerify holds the loaded packet filter to the shipped one, and site4
// to what crew-net puts in it. It only looks.
func (s *Server) nftVerify(ctx context.Context) (*Site4Status, error) {
	if err := s.verifyRuleset(ctx); err != nil {
		return nil, err
	}
	return s.site4Ready(ctx)
}

func (s *Server) verifyRuleset(ctx context.Context) error {
	up, err := s.uplink()
	if err != nil {
		return err
	}
	ref, err := s.Sys.Reference(up)
	if err != nil {
		return fail(ErrFailed, "loading the reference ruleset: %v", err)
	}
	nft, err := s.Sys.Run(ctx, nil, "nft", "-j", "list", "table", "inet", "crew")
	if err != nil {
		return fail(ErrNftMismatch, "%v", err)
	}
	mangle, err := s.Sys.Run(ctx, nil, "iptables-nft-save", "-t", "mangle")
	if err != nil {
		return fail(ErrNftMismatch, "%v", err)
	}
	if err := ruleset.Compare(ref, ruleset.Listing{Nft: nft, Mangle: string(mangle)}); err != nil {
		return fail(ErrNftMismatch, "%v", err)
	}
	return nil
}

// NetUp is crew-net at boot (§12.2, §14.2): the crew0 dummy interface
// with the service address, the ruleset and the connection cap loaded
// once, vm_pairs for any tap that already exists (a restart of
// crew-net), and site4.
func (s *Server) NetUp(ctx context.Context) error {
	up, err := s.findUplink(ctx)
	if err != nil {
		return err
	}
	if !s.Sys.Exists("/sys/class/net/crew0") {
		if _, err := s.Sys.Run(ctx, nil, "ip", "link", "add", "crew0", "type", "dummy"); err != nil {
			return err
		}
	}
	for _, argv := range [][]string{
		{"ip", "addr", "replace", ServiceIP + "/32", "dev", "crew0"},
		{"ip", "link", "set", "dev", "crew0", "up"},
	} {
		if _, err := s.Sys.Run(ctx, nil, argv...); err != nil {
			return err
		}
	}
	script, err := ruleset.LoadScript(etc.NftConf, up)
	if err != nil {
		return err
	}
	if _, err := s.Sys.Run(ctx, []byte(script), "nft", "-f", "-"); err != nil {
		return fmt.Errorf("loading nft.conf: %w", err)
	}
	if _, err := s.Sys.Run(ctx, []byte(etc.ConnlimitRules), "iptables-nft-restore"); err != nil {
		return fmt.Errorf("loading connlimit.rules: %w", err)
	}
	if err := s.Sys.WriteFile(uplinkFile, []byte(up+"\n")); err != nil {
		return err
	}
	for _, dev := range s.Sys.Glob("/sys/class/net/crewt*") {
		n, err := strconv.Atoi(strings.TrimPrefix(dev, "/sys/class/net/crewt"))
		if err != nil {
			continue
		}
		if l, err := s.Net.Lease(n); err == nil {
			if err := s.pair(ctx, "add", l); err != nil {
				return err
			}
		}
	}
	return s.RefreshSite4(ctx)
}

// ServiceIP is the guests' one host address (§14.1). nft.conf names it.
const ServiceIP = "10.199.0.1"

// findUplink is CREW_UPLINK from the agent's env, else the interface of
// the default route.
func (s *Server) findUplink(ctx context.Context) (string, error) {
	if up := s.agentEnv()["CREW_UPLINK"]; up != "" {
		return up, ruleset.CheckUplink(up)
	}
	out, err := s.Sys.Run(ctx, nil, "ip", "-j", "-4", "route", "show", "default")
	if err != nil {
		return "", err
	}
	var routes []struct {
		Dev string `json:"dev"`
	}
	if err := json.Unmarshal(out, &routes); err != nil || len(routes) == 0 {
		return "", fmt.Errorf("no default route to find the uplink by; set CREW_UPLINK")
	}
	return routes[0].Dev, ruleset.CheckUplink(routes[0].Dev)
}

// agentEnv reads the agent's env file for the two settings crew-net
// takes from it. It's the agent's file, so it's parsed here, never
// handed to systemd as an EnvironmentFile for a root process.
func (s *Server) agentEnv() map[string]string {
	out := map[string]string{}
	body, err := s.Sys.ReadFile(s.Paths.AgentEnv(), 64<<10)
	if err != nil {
		return out
	}
	sc := bufio.NewScanner(bytes.NewReader(body))
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !ok || (k != "CREW_UPLINK" && k != "CREW_EXTRA_BLOCKED") {
			continue
		}
		out[k] = strings.Trim(strings.TrimSpace(v), `"'`)
	}
	return out
}

// -- the box -----------------------------------------------------------------------

func (s *Server) reboot(ctx context.Context, bootID string, force bool) (Response, error) {
	body, err := s.Sys.ReadFile(bootIDFile, 64)
	if err != nil {
		return Response{}, err
	}
	if strings.TrimSpace(string(body)) != bootID {
		return Response{Already: true}, nil
	}
	if !force {
		ids, err := s.list(ctx, true)
		if err != nil {
			return Response{}, err
		}
		if len(ids) > 0 {
			return Response{}, fail(ErrBusy, "%d VMs are running", len(ids))
		}
	}
	_, err = s.Sys.Run(ctx, nil, "systemd-run", "--on-active=5", "systemctl", "reboot")
	return Response{}, err
}

var versionRe = regexp.MustCompile(`v?(\d+\.\d+\.\d+)`)

func (s *Server) info(ctx context.Context) *Info {
	i := &Info{Vmctl: s.Version}
	if out, err := s.Sys.Run(ctx, nil, s.Paths.Firecracker(), "--version"); err == nil {
		if m := versionRe.FindStringSubmatch(firstLine(out)); m != nil {
			i.Firecracker = m[1]
		}
	}
	if out, err := s.Sys.Run(ctx, nil, "systemctl", "--version"); err == nil {
		f := strings.Fields(firstLine(out))
		if len(f) >= 2 && f[0] == "systemd" {
			i.Systemd, _ = strconv.Atoi(f[1])
		}
	}
	return i
}

func firstLine(b []byte) string {
	line, _, _ := strings.Cut(string(b), "\n")
	return line
}

// -- exit records ----------------------------------------------------------------------

// ExitRecord is how a VM's unit ended, from the variables systemd gives
// ExecStopPost: SERVICE_RESULT, EXIT_CODE and EXIT_STATUS.
type ExitRecord struct {
	ServiceResult string `json:"service_result"`
	ExitCode      string `json:"exit_code"`
	ExitStatus    string `json:"exit_status"`
	Code          int    `json:"code"` // the status, or 128 + the signal
	At            int64  `json:"at"`
}

var (
	resultRe = regexp.MustCompile(`\A[a-z][a-z-]{0,63}\z`)
	signals  = map[string]int{"HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "BUS": 7,
		"FPE": 8, "KILL": 9, "USR1": 10, "SEGV": 11, "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15, "SYS": 31}
)

// NewExitRecord checks systemd's values and builds the record.
func NewExitRecord(result, code, status string, at time.Time) (ExitRecord, error) {
	if !resultRe.MatchString(result) {
		return ExitRecord{}, fmt.Errorf("SERVICE_RESULT %q", result)
	}
	r := ExitRecord{ServiceResult: result, ExitCode: code, ExitStatus: status, At: at.Unix()}
	switch code {
	case "exited":
		n, err := strconv.Atoi(status)
		if err != nil || n < 0 || n > 255 {
			return ExitRecord{}, fmt.Errorf("EXIT_STATUS %q", status)
		}
		r.Code = n
	case "killed", "dumped":
		n, ok := signals[status]
		if !ok {
			return ExitRecord{}, fmt.Errorf("EXIT_STATUS %q", status)
		}
		r.Code = 128 + n
	default:
		return ExitRecord{}, fmt.Errorf("EXIT_CODE %q", code)
	}
	return r, nil
}

// RecordExit is `crew-vmctl exited <vm_id>`, the unit's ExecStopPost.
func (s *Server) RecordExit(vmID string, env func(string) string) error {
	if !IsUUID(vmID) {
		return fmt.Errorf("vm_id must be a UUID")
	}
	rec, err := NewExitRecord(env("SERVICE_RESULT"), env("EXIT_CODE"), env("EXIT_STATUS"), s.Now())
	if err != nil {
		return err
	}
	body, _ := json.Marshal(rec)
	if err := s.Sys.CreateFile(s.Paths.Exited(vmID), append(body, '\n')); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return nil
}
