//go:build integration && darwin

// Package integration boots real VMs with crew-vz under Virtualization.
// framework. Run it with `make integration` (or see README.md): it needs
//
//	CREW_VZ_BIN    a signed crew-vz (make crew-vz)
//	CREW_VZ_GUEST  a dir with Image and rootfs.ext4 (make guest)
//
// Optional:
//
//	CREW_VZ_DL_URL      an internet URL the guest downloads to measure
//	                    real-world throughput (default: none)
//	CREW_VZ_SANDBOX=1   also run the boot test under sandbox.sb
package integration

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vz/ctlproto"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
)

func mustEnv(t *testing.T, k string) string {
	t.Helper()
	v := os.Getenv(k)
	if v == "" {
		t.Skipf("%s not set (run make integration)", k)
	}
	return v
}

type box struct {
	t       *testing.T
	bin     string
	guest   string
	data    string
	sock    string
	daemon  *exec.Cmd
	sandbox string
	cacheIP string
}

func newBox(t *testing.T) *box {
	t.Helper()
	b := &box{t: t, bin: mustEnv(t, "CREW_VZ_BIN"), guest: mustEnv(t, "CREW_VZ_GUEST")}
	// Unix socket paths are capped at 104 bytes: keep the data dir short.
	d, err := os.MkdirTemp("/tmp", "cvzi")
	if err != nil {
		t.Fatal(err)
	}
	b.data, b.sock = d, filepath.Join(d, "vzd.sock")
	img := filepath.Join(d, "images", "test")
	os.MkdirAll(img, 0o755)
	clone(t, filepath.Join(b.guest, "Image"), filepath.Join(img, "Image"))
	t.Cleanup(func() {
		b.stopDaemon()
		if t.Failed() {
			t.Logf("left %s for inspection", d)
			return
		}
		os.RemoveAll(d)
	})
	return b
}

// clone copies with clonefile(2), as the agent does.
func clone(t *testing.T, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-c", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp -c %s: %v %s", src, err, out)
	}
}

func (b *box) startDaemon() {
	b.t.Helper()
	args := []string{"daemon", "--socket", b.sock, "--data-dir", b.data, "-v"}
	if b.sandbox != "" {
		args = append(args, "--sandbox", b.sandbox)
	}
	cmd := exec.Command(b.bin, args...)
	logf, _ := os.OpenFile(filepath.Join(b.data, "vzd.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		b.t.Fatal(err)
	}
	b.daemon = cmd
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := ctlproto.Call(context.Background(), b.sock, ctlproto.Request{Op: "list"}); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	b.t.Fatal("crew-vzd never answered")
}

func (b *box) stopDaemon() {
	if b.daemon == nil {
		return
	}
	b.daemon.Process.Signal(syscall.SIGTERM)
	b.daemon.Wait()
	b.daemon = nil
}

func (b *box) killDaemon() {
	b.daemon.Process.Kill()
	b.daemon.Wait()
	b.daemon = nil
}

func (b *box) call(req ctlproto.Request) ctlproto.Response {
	b.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	resp, err := ctlproto.Call(ctx, b.sock, req)
	if err != nil {
		b.t.Fatal(err)
	}
	return resp
}

type vmOpts struct {
	mode     string
	extra    string
	vcpus    int
	memMiB   int
	mtu      int
	cacheIP  string
	deadline time.Duration
}

type vm struct {
	b        *box
	id       string
	dir      string
	guestAPI *guestAPI
}

func (b *box) addVM(id string, o vmOpts) *vm {
	b.t.Helper()
	dir := filepath.Join(b.data, "vms", id)
	os.MkdirAll(dir, 0o750)
	clone(b.t, filepath.Join(b.guest, "rootfs.ext4"), filepath.Join(dir, "rootfs.ext4"))
	if o.vcpus == 0 {
		o.vcpus = 2
	}
	if o.memMiB == 0 {
		o.memMiB = 1024
	}
	cmdline := fmt.Sprintf("console=hvc0 panic=1 quiet loglevel=4 root=/dev/vda rw rootfstype=ext4 "+
		"ip=10.200.0.2::10.200.0.1:255.255.255.252::eth0:off crew.vm=%s crew.token=test crew.api=http://10.199.0.1:7777 crewtest.mode=%s %s",
		id, o.mode, o.extra)
	cfg := map[string]any{
		"vm_id": id, "vcpus": o.vcpus, "memory_mib": o.memMiB,
		"kernel":       filepath.Join(b.data, "images", "test", "Image"),
		"cmdline":      strings.TrimSpace(cmdline),
		"disk":         filepath.Join(dir, "rootfs.ext4"),
		"console_log":  filepath.Join(dir, "console.log"),
		"guest_socket": filepath.Join(dir, "guest.sock"),
		"ctl_socket":   filepath.Join(dir, "ctl.sock"),
		"exited_path":  filepath.Join(dir, "vz-exited.json"),
		"lease":        map[string]string{"gateway": "10.200.0.1/30", "guest": "10.200.0.2/30", "mac": "02:00:0a:c8:00:02"},
		"service_ip":   "10.199.0.1",
		"dns_fallback": "1.1.1.1:53",
		"site4":        []string{"203.0.113.0/24"},
	}
	if o.cacheIP != "" {
		cfg["cache_addr"] = o.cacheIP
	}
	if o.mtu != 0 {
		cfg["mtu"] = o.mtu
	}
	raw, _ := json.MarshalIndent(cfg, "", "  ")
	os.WriteFile(filepath.Join(dir, "vz.json"), raw, 0o640)
	v := &vm{b: b, id: id, dir: dir}
	v.guestAPI = serveGuestAPI(b.t, filepath.Join(dir, "guest.sock"), v)
	return v
}

func (v *vm) start(deadline time.Duration) (ctlproto.Response, time.Time) {
	if deadline == 0 {
		deadline = 10 * time.Minute
	}
	at := time.Now()
	return v.b.call(ctlproto.Request{Op: "start", VMID: v.id, Deadline: at.Add(deadline).Unix()}), at
}

func (v *vm) status() ctlproto.Response {
	return v.b.call(ctlproto.Request{Op: "status", VMID: v.id})
}

func (v *vm) waitExited(timeout time.Duration) exitrec.Record {
	v.b.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp := v.status()
		if resp.OK && resp.VM.State == "exited" && resp.VM.Exited != nil {
			return *resp.VM.Exited
		}
		time.Sleep(25 * time.Millisecond)
	}
	v.b.t.Fatalf("%s did not exit within %v; console:\n%s", v.id, timeout, v.console())
	return exitrec.Record{}
}

func (v *vm) console() string {
	b, _ := os.ReadFile(filepath.Join(v.dir, "console.log"))
	return string(b)
}

// guestAPI plays the agent's guest API on the VM's guest.sock, speaking
// guestinit's line protocol.
type guestAPI struct {
	mu       sync.Mutex
	hello    chan time.Time
	ready    chan time.Time
	reports  chan json.RawMessage
	statusAt json.RawMessage // helper status captured when the report came in
	vm       *vm
}

func serveGuestAPI(t *testing.T, path string, v *vm) *guestAPI {
	g := &guestAPI{hello: make(chan time.Time, 1), ready: make(chan time.Time, 1), reports: make(chan json.RawMessage, 1), vm: v}
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go g.serve(c)
		}
	}()
	return g
}

func (g *guestAPI) serve(c net.Conn) {
	defer c.Close()
	rd := bufio.NewReaderSize(c, 1<<20)
	line, err := rd.ReadString('\n')
	if err != nil {
		return
	}
	cmd, arg, _ := strings.Cut(strings.TrimSpace(line), " ")
	switch cmd {
	case "HELLO":
		select {
		case g.hello <- time.Now():
		default:
		}
		fmt.Fprintf(c, "OK %s\n", arg)
	case "READY":
		select {
		case g.ready <- time.Now():
		default:
		}
		fmt.Fprintf(c, "OK\n")
	case "DOWNLOAD":
		n, _ := strconv.Atoi(arg)
		buf := make([]byte, 256<<10)
		for sent := 0; sent < n; {
			k, err := c.Write(buf[:min(len(buf), n-sent)])
			if err != nil {
				return
			}
			sent += k
		}
	case "UPLOAD":
		n, _ := strconv.ParseInt(arg, 10, 64)
		if got, _ := io.CopyN(io.Discard, rd, n); got == n {
			fmt.Fprintf(c, "OK\n")
		}
	case "REPORT":
		resp, err := ctlproto.Call(context.Background(), filepath.Join(g.vm.dir, "ctl.sock"), ctlproto.Request{Op: "status"})
		if err == nil && resp.VM != nil {
			g.mu.Lock()
			g.statusAt = resp.VM.Net
			g.mu.Unlock()
		}
		g.reports <- json.RawMessage(arg)
		fmt.Fprintf(c, "BYE\n")
	}
}

func waitFor[T any](t *testing.T, ch <-chan T, d time.Duration, what string, v *vm) T {
	t.Helper()
	select {
	case x := <-ch:
		return x
	case <-time.After(d):
		t.Fatalf("timed out waiting for %s; console:\n%s", what, v.console())
	}
	var zero T
	return zero
}

type probe struct {
	Target string  `json:"target"`
	OK     bool    `json:"ok"`
	Err    string  `json:"err"`
	Ms     float64 `json:"ms"`
}

type report struct {
	UptimeAtInit    float64            `json:"uptime_at_init_s"`
	UptimeAtHello   float64            `json:"uptime_at_hello_s"`
	Hello           string             `json:"hello"`
	DNS             probe              `json:"dns"`
	Internet        []probe            `json:"internet"`
	BlockedTCP      []probe            `json:"blocked_tcp"`
	BlockedUDP      []probe            `json:"blocked_udp"`
	ServiceOther    []probe            `json:"service_other"`
	PingService     probe              `json:"ping_service"`
	PingInternet    probe              `json:"ping_internet"`
	ARPGateway      probe              `json:"arp_gateway"`
	ARPOther        []probe            `json:"arp_other"`
	IPv6            probe              `json:"ipv6"`
	LocalDownload   map[string]float64 `json:"local_download_mbps"`
	LocalUpload     map[string]float64 `json:"local_upload_mbps"`
	CacheDownload   map[string]float64 `json:"cache_download_mbps"`
	InternetDL      map[string]float64 `json:"internet_download_mbps"`
	InternetDLError string             `json:"internet_download_error"`
}

// lanIP is the Mac's outbound IPv4 address.
func lanIP(t *testing.T) string {
	c, err := net.Dial("udp4", "1.1.1.1:53")
	if err != nil {
		return ""
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).IP.String()
}

// serveFakeCache stands in for the cache VM on <lan ip>:80, serving
// /bytes/<n>. It measures the netstack's TCP path end to end (gVisor
// endpoint to a host TCP socket), the same path as a direct dial.
func serveFakeCache(t *testing.T) string {
	ip := lanIP(t)
	if ip == "" {
		return ""
	}
	// macOS lets unprivileged processes bind ports below 1024 only on the
	// wildcard address; refuse anyone but the Mac itself.
	ln, err := net.Listen("tcp4", ":80")
	if err != nil {
		t.Logf("fake cache: can't listen on :80 (%v); skipping the cache throughput probe", err)
		return ""
	}
	t.Cleanup(func() { ln.Close() })
	ln = localOnly{ln, ip}
	buf := make([]byte, 1<<20)
	go http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/bytes/"))
		w.Header().Set("Content-Length", strconv.Itoa(n))
		for sent := 0; sent < n; {
			k, err := w.Write(buf[:min(len(buf), n-sent)])
			if err != nil {
				return
			}
			sent += k
		}
	}))
	return ip
}

type localOnly struct {
	net.Listener
	ip string
}

func (l localOnly) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if h, _, _ := net.SplitHostPort(c.RemoteAddr().String()); h == l.ip {
			return c, nil
		}
		c.Close()
	}
}

func expectRefused(t *testing.T, ps []probe, what string) {
	t.Helper()
	if len(ps) == 0 {
		t.Errorf("%s: no probes", what)
	}
	for _, p := range ps {
		if p.OK {
			t.Errorf("%s: %s was reachable", what, p.Target)
		} else if !strings.Contains(p.Err, "refused") {
			t.Errorf("%s: %s failed with %q, want connection refused", what, p.Target, p.Err)
		} else if p.Ms > 1000 {
			t.Errorf("%s: refusing %s took %.0fms", what, p.Target, p.Ms)
		}
	}
}

func checkNetReport(t *testing.T, r report, net json.RawMessage) {
	t.Helper()
	if !strings.HasPrefix(r.Hello, "OK ") {
		t.Errorf("guest API hello: %q", r.Hello)
	}
	if !r.DNS.OK {
		t.Errorf("DNS via 10.199.0.1:53: %s", r.DNS.Err)
	}
	for _, p := range r.Internet {
		if !p.OK {
			t.Errorf("internet TCP %s: %s", p.Target, p.Err)
		}
	}
	expectRefused(t, r.BlockedTCP, "blocked TCP")
	expectRefused(t, r.BlockedUDP, "blocked UDP")
	expectRefused(t, r.ServiceOther, "service address, other ports")
	if !r.PingService.OK {
		t.Errorf("ping 10.199.0.1: %s", r.PingService.Err)
	}
	if r.PingInternet.OK {
		t.Error("ping 1.1.1.1 answered: echo must not be forwarded")
	}
	if !r.ARPGateway.OK {
		t.Errorf("ARP for the gateway: %s", r.ARPGateway.Err)
	}
	for _, p := range r.ARPOther {
		if p.OK {
			t.Errorf("ARP for %s answered", p.Target)
		}
	}
	if r.IPv6.OK {
		t.Error("IPv6 connection succeeded")
	}
	var st struct {
		Drops map[string]uint64 `json:"drops"`
	}
	json.Unmarshal(net, &st)
	if st.Drops["ipv6"] == 0 {
		t.Errorf("helper dropped no IPv6 frames (drops %v); the guest sends RS/DAD at boot", st.Drops)
	}
	t.Logf("helper drop counters: %v", st.Drops)
}

func runNetTest(t *testing.T, b *box, id string, o vmOpts) report {
	o.mode = "net"
	v := b.addVM(id, o)
	resp, at := v.start(0)
	if !resp.OK {
		t.Fatalf("start: %+v", resp)
	}
	started := time.Since(at)
	hello := waitFor(t, v.guestAPI.hello, 60*time.Second, "HELLO", v)
	raw := waitFor(t, v.guestAPI.reports, 5*time.Minute, "REPORT", v)
	rec := v.waitExited(30 * time.Second)
	if rec.Code != 0 || rec.Reason != exitrec.ReasonGuestStopped {
		t.Errorf("exited %+v", rec)
	}
	var r report
	if err := json.Unmarshal(raw, &r); err != nil {
		t.Fatalf("report %s: %v", raw, err)
	}
	v.guestAPI.mu.Lock()
	netStats := v.guestAPI.statusAt
	v.guestAPI.mu.Unlock()
	t.Logf("boot: start verb returned in %v; guest API HELLO %v after start (kernel uptime %.3fs at init, %.3fs at HELLO)",
		started.Round(time.Millisecond), hello.Sub(at).Round(time.Millisecond), r.UptimeAtInit, r.UptimeAtHello)
	t.Logf("throughput (Mbit/s): guest.sock download %v, upload %v; cache path %v; internet %v %s",
		r.LocalDownload, r.LocalUpload, r.CacheDownload, r.InternetDL, r.InternetDLError)
	checkNetReport(t, r, netStats)
	return r
}

func TestBootAndNetworkPolicy(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	extra := ""
	if u := os.Getenv("CREW_VZ_DL_URL"); u != "" {
		extra += " crewtest.dl=" + u
	}
	runNetTest(t, b, "net1", vmOpts{extra: extra, vcpus: 4, memMiB: 2048})
}

// mtus is CREW_VZ_MTUS (comma-separated), default 1500.
func mtus() []int {
	var out []int
	for _, s := range strings.Split(os.Getenv("CREW_VZ_MTUS"), ",") {
		if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
			out = append(out, n)
		}
	}
	if len(out) == 0 {
		out = []int{1500}
	}
	return out
}

// TestCachePathThroughput measures guest TCP downloads through the netstack
// to a host TCP socket (spike S4): 10.199.0.1:80 is forwarded to
// cache_addr, here a fake cache on the Mac's LAN address.
func TestCachePathThroughput(t *testing.T) {
	cache := serveFakeCache(t)
	if cache == "" {
		t.Skip("no fake cache")
	}
	b := newBox(t)
	b.startDaemon()
	for _, mtu := range mtus() {
		v := b.addVM(fmt.Sprintf("cache%d", mtu), vmOpts{mode: "cache", cacheIP: cache, vcpus: 4, memMiB: 2048, mtu: mtu})
		if resp, _ := v.start(0); !resp.OK {
			t.Fatalf("start: %+v", resp)
		}
		raw := waitFor(t, v.guestAPI.reports, 5*time.Minute, "REPORT", v)
		if rec := v.waitExited(30 * time.Second); rec.Code != 0 {
			t.Errorf("exited %+v", rec)
		}
		var r report
		json.Unmarshal(raw, &r)
		if len(r.CacheDownload) == 0 {
			t.Fatalf("no cache downloads; console:\n%s", v.console())
		}
		t.Logf("cache path (guest -> 10.199.0.1:80 -> %s:80), mtu %d: %v Mbit/s", cache, mtu, r.CacheDownload)
		for size, mbps := range r.CacheDownload {
			if mbps < 1000 {
				t.Errorf("%s at %.0f Mbit/s, below the 1 Gbit/s floor (S4)", size, mbps)
			}
		}
	}
}

func TestSandboxedBoot(t *testing.T) {
	if os.Getenv("CREW_VZ_SANDBOX") == "" {
		t.Skip("set CREW_VZ_SANDBOX=1 to run helpers under sandbox.sb (spike S3)")
	}
	b := newBox(t)
	wd, _ := os.Getwd()
	b.sandbox = filepath.Join(wd, "..", "sandbox.sb")
	b.startDaemon()
	runNetTest(t, b, "sbx1", vmOpts{extra: "crewtest.quick=1"})
}

func startWaiting(t *testing.T, b *box, id string, deadline time.Duration) (*vm, int) {
	t.Helper()
	v := b.addVM(id, vmOpts{mode: "wait", vcpus: 1, memMiB: 512})
	resp, _ := v.start(deadline)
	if !resp.OK {
		t.Fatalf("start: %+v", resp)
	}
	waitFor(t, v.guestAPI.ready, 60*time.Second, "READY", v)
	return v, resp.VM.PID
}

func TestGracefulStopIsThePowerButton(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v, _ := startWaiting(t, b, "grace1", 0)
	at := time.Now()
	if resp := b.call(ctlproto.Request{Op: "stop", VMID: v.id}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	rec := v.waitExited(10 * time.Second)
	t.Logf("graceful stop: guest off %v after the request", time.Since(at).Round(time.Millisecond))
	if rec.Code != 0 {
		t.Fatalf("exited %+v", rec)
	}
	if !strings.Contains(v.console(), "power button pressed") {
		t.Fatalf("guest never saw the power button; console:\n%s", v.console())
	}
}

func TestForceStop(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v, pid := startWaiting(t, b, "force1", 0)
	at := time.Now()
	if resp := b.call(ctlproto.Request{Op: "stop", VMID: v.id, Force: true}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	rec := v.waitExited(2 * time.Second)
	t.Logf("force stop: %v", time.Since(at).Round(time.Millisecond))
	if rec.Code != 2 || rec.Reason != exitrec.ReasonKilled {
		t.Fatalf("exited %+v", rec)
	}
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatal("helper still running")
	}
	// A used disk is never booted again.
	if resp, _ := v.start(0); resp.OK || resp.Error != ctlproto.ErrAlreadyExited {
		t.Fatalf("restart: %+v", resp)
	}
}

func TestDeadlineKillsTheVM(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v, _ := startWaiting(t, b, "dl1", 6*time.Second)
	rec := v.waitExited(15 * time.Second)
	if rec.Code != 3 || rec.Reason != exitrec.ReasonDeadline {
		t.Fatalf("exited %+v", rec)
	}
}

func TestDeadlineWhileDaemonIsDown(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v, pid := startWaiting(t, b, "dl2", 6*time.Second)
	b.killDaemon()
	deadline := time.Now().Add(15 * time.Second)
	for syscall.Kill(pid, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	rec, err := exitrec.Read(filepath.Join(v.dir, exitrec.FileName))
	if err != nil || rec.Code != 3 {
		t.Fatalf("exited.json %+v %v", rec, err)
	}
}

func TestDaemonRestartReadopts(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v, pid := startWaiting(t, b, "adopt1", 0)
	b.killDaemon() // SIGKILL: no chance to clean up
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("helper died with the daemon: %v", err)
	}
	b.startDaemon()
	list := b.call(ctlproto.Request{Op: "list"})
	if !list.OK || len(list.VMs) != 1 || list.VMs[0].VMID != v.id || list.VMs[0].State != "running" {
		t.Fatalf("list after restart: %+v", list)
	}
	if resp := b.call(ctlproto.Request{Op: "stop", VMID: v.id, Force: true}); !resp.OK {
		t.Fatalf("stop: %+v", resp)
	}
	if rec := v.waitExited(5 * time.Second); rec.Code != 2 {
		t.Fatalf("exited %+v", rec)
	}
}

func TestConsoleFloodIsCapped(t *testing.T) {
	b := newBox(t)
	b.startDaemon()
	v := b.addVM("flood1", vmOpts{mode: "flood", extra: "crewtest.flood_mib=40", vcpus: 1, memMiB: 512})
	if resp, _ := v.start(0); !resp.OK {
		t.Fatalf("start: %+v", resp)
	}
	rec := v.waitExited(2 * time.Minute)
	if rec.Code != 0 {
		t.Fatalf("exited %+v", rec)
	}
	st, err := os.Stat(filepath.Join(v.dir, "console.log"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() > 8<<20 {
		t.Fatalf("console.log is %d bytes", st.Size())
	}
	c := v.console()
	if !strings.Contains(c, "crew-vz: console truncated") || !strings.Contains(c, "crewtest: init up") {
		t.Fatal("console.log lacks the head or the truncation marker")
	}
	if !strings.Contains(c[len(c)-4096:], "crewtest: flooded") {
		t.Fatal("console.log tail is not the end of the stream")
	}
	t.Logf("console.log: %d bytes after a 40 MiB flood", st.Size())
}
