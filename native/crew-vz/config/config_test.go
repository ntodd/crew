package config

import (
	"encoding/binary"
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var testLimits = Limits{MinVCPUs: 1, MaxVCPUs: 8, MinMemoryMiB: 256, MaxMemoryMiB: 16384}

// fixture lays out a data dir the way the agent would: an image under
// images/ and a VM directory with its disk clone.
type fixture struct {
	dataDir string
	vmDir   string
	cfg     *Config
}

func shortTempDir(t *testing.T) string {
	t.Helper()
	// Unix socket paths are limited to 104 bytes on macOS, and the default
	// temp dir is long, so tests live under /tmp.
	d, err := os.MkdirTemp("/tmp", "cvzcfg")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

func writeKernel(t *testing.T, path string) {
	t.Helper()
	// Minimal arm64 Image header: magic "ARM\x64" at offset 0x38.
	img := make([]byte, 4096)
	binary.LittleEndian.PutUint32(img[0x38:], 0x644d5241)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, img, 0o644); err != nil {
		t.Fatal(err)
	}
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	data := shortTempDir(t)
	vmID := "vm1"
	vmDir := filepath.Join(data, "vms", vmID)
	if err := os.MkdirAll(vmDir, 0o750); err != nil {
		t.Fatal(err)
	}
	kernel := filepath.Join(data, "images", "img1", "Image")
	writeKernel(t, kernel)
	disk := filepath.Join(vmDir, "rootfs.ext4")
	if err := os.WriteFile(disk, make([]byte, 1<<20), 0o640); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{
		VMID:        vmID,
		VCPUs:       2,
		MemoryMiB:   2048,
		Kernel:      kernel,
		Cmdline:     "console=hvc0 panic=1 root=/dev/vda rw",
		Disk:        disk,
		ConsoleLog:  filepath.Join(vmDir, "console.log"),
		GuestSocket: filepath.Join(vmDir, "guest.sock"),
		CtlSocket:   filepath.Join(vmDir, "ctl.sock"),
		ExitedPath:  filepath.Join(vmDir, "exited.json"),
		Lease:       Lease{Gateway: "10.200.0.1/30", Guest: "10.200.0.2/30", MAC: "02:00:0a:c8:00:02"},
		ServiceIP:   "10.199.0.1",
		CacheAddr:   "192.168.64.5",
		Site4:       []string{"203.0.113.7/32", "192.168.1.0/24"},
	}
	return &fixture{dataDir: data, vmDir: vmDir, cfg: cfg}
}

func (f *fixture) validate() error {
	return f.cfg.Validate(f.dataDir, testLimits)
}

func TestValidConfig(t *testing.T) {
	f := newFixture(t)
	if err := f.validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if f.cfg.MaxConns != DefaultMaxConns {
		t.Errorf("max_conns default = %d, want %d", f.cfg.MaxConns, DefaultMaxConns)
	}
	if f.cfg.MTU != DefaultMTU {
		t.Errorf("mtu default = %d, want %d", f.cfg.MTU, DefaultMTU)
	}
	n := f.cfg.Net()
	if n.Gateway != netip.MustParseAddr("10.200.0.1") || n.Guest != netip.MustParseAddr("10.200.0.2") {
		t.Errorf("lease parsed wrong: %+v", n)
	}
	if n.ServiceIP != netip.MustParseAddr("10.199.0.1") {
		t.Errorf("service ip = %v", n.ServiceIP)
	}
	if len(n.Site4) != 2 || n.Site4[1] != netip.MustParsePrefix("192.168.1.0/24") {
		t.Errorf("site4 = %v", n.Site4)
	}
}

func TestServiceIPDefaults(t *testing.T) {
	f := newFixture(t)
	f.cfg.ServiceIP = ""
	if err := f.validate(); err != nil {
		t.Fatal(err)
	}
	if f.cfg.ServiceIP != DefaultServiceIP {
		t.Errorf("service_ip = %q", f.cfg.ServiceIP)
	}
}

func TestLoadRejectsUnknownFields(t *testing.T) {
	f := newFixture(t)
	raw, _ := json.Marshal(f.cfg)
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	m["surprise"] = true
	raw, _ = json.Marshal(m)
	p := filepath.Join(f.vmDir, "vz.json")
	if err := os.WriteFile(p, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(p); err == nil || !strings.Contains(err.Error(), "surprise") {
		t.Fatalf("expected unknown field error, got %v", err)
	}
}

func TestLoadRoundTrip(t *testing.T) {
	f := newFixture(t)
	raw, _ := json.Marshal(f.cfg)
	p := filepath.Join(f.vmDir, "vz.json")
	if err := os.WriteFile(p, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	got, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := got.Validate(f.dataDir, testLimits); err != nil {
		t.Fatal(err)
	}
	if got.VMID != "vm1" || got.Lease.MAC != f.cfg.Lease.MAC {
		t.Fatalf("round trip lost data: %+v", got)
	}
}

func TestLoadRejectsSymlinkedConfig(t *testing.T) {
	f := newFixture(t)
	raw, _ := json.Marshal(f.cfg)
	real := filepath.Join(f.vmDir, "real.json")
	if err := os.WriteFile(real, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(f.vmDir, "vz.json")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(link); err == nil {
		t.Fatal("expected symlinked vz.json to be refused")
	}
}

func TestPathRules(t *testing.T) {
	outside := shortTempDir(t)
	outsideKernel := filepath.Join(outside, "Image")
	writeKernel(t, outsideKernel)

	cases := []struct {
		name   string
		mutate func(f *fixture)
		want   string
	}{
		{"kernel outside data dir", func(f *fixture) { f.cfg.Kernel = outsideKernel }, "kernel"},
		{"relative path", func(f *fixture) { f.cfg.ConsoleLog = "vms/vm1/console.log" }, "console_log"},
		{"dotdot", func(f *fixture) {
			f.cfg.Disk = f.vmDir + "/../vm1/rootfs.ext4"
		}, "disk"},
		{"dotdot escaping", func(f *fixture) {
			f.cfg.Kernel = f.dataDir + "/../" + filepath.Base(outside) + "/Image"
		}, "kernel"},
		{"per-vm file in another vm dir", func(f *fixture) {
			other := filepath.Join(f.dataDir, "vms", "vm2")
			os.MkdirAll(other, 0o750)
			f.cfg.ExitedPath = filepath.Join(other, "exited.json")
		}, "exited_path"},
		{"per-vm file at data dir root", func(f *fixture) {
			f.cfg.ConsoleLog = filepath.Join(f.dataDir, "console.log")
		}, "console_log"},
		{"disk missing", func(f *fixture) { f.cfg.Disk = filepath.Join(f.vmDir, "nope.img") }, "disk"},
		{"disk is a directory", func(f *fixture) {
			d := filepath.Join(f.vmDir, "dir.img")
			os.Mkdir(d, 0o750)
			f.cfg.Disk = d
		}, "disk"},
		{"disk symlink", func(f *fixture) {
			l := filepath.Join(f.vmDir, "link.img")
			os.Symlink(f.cfg.Disk, l)
			f.cfg.Disk = l
		}, "disk"},
		{"disk hard link", func(f *fixture) {
			l := filepath.Join(f.vmDir, "hard.img")
			os.Link(f.cfg.Disk, l)
			f.cfg.Disk = l
		}, "disk"},
		{"kernel symlink to outside", func(f *fixture) {
			l := filepath.Join(f.dataDir, "images", "img1", "Image.link")
			os.Symlink(outsideKernel, l)
			f.cfg.Kernel = l
		}, "kernel"},
		{"directory component symlink", func(f *fixture) {
			// images/evil -> outside dir: the leaf is a regular file, but a
			// parent is a symlink that leaves the data dir.
			os.Symlink(outside, filepath.Join(f.dataDir, "images", "evil"))
			f.cfg.Kernel = filepath.Join(f.dataDir, "images", "evil", "Image")
		}, "kernel"},
		{"vm dir is a symlink", func(f *fixture) {
			// Swap vms/vm1 for a symlink to a directory outside.
			real := filepath.Join(outside, "vm1")
			os.Rename(f.vmDir, real)
			os.Symlink(real, f.vmDir)
		}, "symlink"},
		{"console log is a symlink", func(f *fixture) {
			os.Symlink(outsideKernel, f.cfg.ConsoleLog)
		}, "console_log"},
		{"kernel not an arm64 Image", func(f *fixture) {
			os.WriteFile(f.cfg.Kernel, []byte("\x1f\x8b gzip"), 0o644)
		}, "kernel"},
		{"socket path too long", func(f *fixture) {
			long := filepath.Join(f.vmDir, strings.Repeat("s", 100)+".sock")
			f.cfg.CtlSocket = long
		}, "ctl_socket"},
		{"same file twice", func(f *fixture) { f.cfg.ExitedPath = f.cfg.ConsoleLog }, "same path"},
		{"kernel is the disk", func(f *fixture) { f.cfg.Kernel = f.cfg.Disk }, "kernel"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tc.mutate(f)
			err := f.validate()
			if err == nil {
				t.Fatalf("expected error mentioning %q, got nil", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

func TestValueRules(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(c *Config)
		want   string
	}{
		{"bad vm id", func(c *Config) { c.VMID = "../x" }, "vm_id"},
		{"empty vm id", func(c *Config) { c.VMID = "" }, "vm_id"},
		{"zero cpus", func(c *Config) { c.VCPUs = 0 }, "vcpus"},
		{"too many cpus", func(c *Config) { c.VCPUs = 9 }, "vcpus"},
		{"too little memory", func(c *Config) { c.MemoryMiB = 128 }, "memory_mib"},
		{"too much memory", func(c *Config) { c.MemoryMiB = 16385 }, "memory_mib"},
		{"empty cmdline", func(c *Config) { c.Cmdline = "" }, "cmdline"},
		{"cmdline with newline", func(c *Config) { c.Cmdline = "a\nb" }, "cmdline"},
		{"cmdline too long", func(c *Config) { c.Cmdline = strings.Repeat("a", 2048) }, "cmdline"},
		{"gateway not .1", func(c *Config) { c.Lease.Gateway = "10.200.0.2/30" }, "lease"},
		{"guest not .2", func(c *Config) { c.Lease.Guest = "10.200.0.3/30" }, "lease"},
		{"different /30s", func(c *Config) { c.Lease.Guest = "10.200.0.6/30" }, "lease"},
		{"wrong prefix", func(c *Config) { c.Lease.Gateway = "10.200.0.1/24" }, "lease"},
		{"ipv6 lease", func(c *Config) { c.Lease.Gateway = "fd00::1/126" }, "lease"},
		{"bad mac", func(c *Config) { c.Lease.MAC = "zz:00:00:00:00:00" }, "mac"},
		{"multicast mac", func(c *Config) { c.Lease.MAC = "01:00:5e:00:00:01" }, "mac"},
		{"gateway's mac", func(c *Config) { c.Lease.MAC = "02:c7:e0:00:00:01" }, "mac"},
		{"service ip v6", func(c *Config) { c.ServiceIP = "::1" }, "service_ip"},
		{"service ip in lease", func(c *Config) { c.ServiceIP = "10.200.0.1" }, "service_ip"},
		{"cache addr loopback", func(c *Config) { c.CacheAddr = "127.0.0.1" }, "cache_addr"},
		{"cache addr with port", func(c *Config) { c.CacheAddr = "192.168.64.5:443" }, "cache_addr"},
		{"cache addr is service ip", func(c *Config) { c.CacheAddr = "10.199.0.1" }, "cache_addr"},
		{"dns fallback bad", func(c *Config) { c.DNSFallback = "dns.google" }, "dns_fallback"},
		{"dns fallback loopback", func(c *Config) { c.DNSFallback = "127.0.0.1:53" }, "dns_fallback"},
		{"site4 garbage", func(c *Config) { c.Site4 = []string{"nope"} }, "site4"},
		{"site4 ipv6", func(c *Config) { c.Site4 = []string{"2001:db8::/32"} }, "site4"},
		{"max conns too high", func(c *Config) { c.MaxConns = 2049 }, "max_conns"},
		{"max conns negative", func(c *Config) { c.MaxConns = -1 }, "max_conns"},
		{"mtu too small", func(c *Config) { c.MTU = 1000 }, "mtu"},
		{"mtu too big", func(c *Config) { c.MTU = 70000 }, "mtu"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tc.mutate(f.cfg)
			err := f.validate()
			if err == nil {
				t.Fatalf("expected error mentioning %q, got nil", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

func TestDNSFallbackDefaultsPort(t *testing.T) {
	f := newFixture(t)
	f.cfg.DNSFallback = "1.1.1.1"
	if err := f.validate(); err != nil {
		t.Fatal(err)
	}
	if got := f.cfg.Net().DNSFallback; got != netip.MustParseAddrPort("1.1.1.1:53") {
		t.Fatalf("dns fallback = %v", got)
	}
}

func TestSite4BareAddress(t *testing.T) {
	f := newFixture(t)
	f.cfg.Site4 = []string{"198.51.100.20"}
	if err := f.validate(); err != nil {
		t.Fatal(err)
	}
	if got := f.cfg.Net().Site4; len(got) != 1 || got[0] != netip.MustParsePrefix("198.51.100.20/32") {
		t.Fatalf("site4 = %v", got)
	}
}

func TestValidateForDir(t *testing.T) {
	f := newFixture(t)
	// The daemon checks that the vm_id in vz.json matches the directory it
	// was read from.
	if err := f.cfg.ValidateAt(filepath.Join(f.vmDir, "vz.json"), f.dataDir, testLimits); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(f.dataDir, "vms", "vm2")
	os.MkdirAll(other, 0o750)
	err := f.cfg.ValidateAt(filepath.Join(other, "vz.json"), f.dataDir, testLimits)
	if err == nil || !strings.Contains(err.Error(), "vm_id") {
		t.Fatalf("expected vm_id/dir mismatch, got %v", err)
	}
}
