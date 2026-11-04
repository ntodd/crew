// Package config reads and validates vz.json, the per-VM file the agent
// writes and crew-vz reads. native/crew-vz/README.md is the contract.
//
// Validation is deliberately strict: crew-vzd runs as a different user from
// the agent, and vz.json is the only thing the agent controls, so every path
// must stay inside the data dir (per-VM files inside the VM's own
// directory), no path component below the data dir may be a symlink, and
// every number must be in range.
package config

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/ntodd/crew/native/crew-vz/exitrec"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

const (
	DefaultServiceIP = "10.199.0.1"
	DefaultMaxConns  = 2048
	MaxMaxConns      = 2048
	DefaultMTU       = 1500
	MinMTU           = 1500 // Virtualization.framework's minimum
	MaxMTU           = 65535
	MaxCmdline       = 2047 // arm64 COMMAND_LINE_SIZE is 2048 including the NUL
	MaxSite4         = 1024
	MaxConfigBytes   = 1 << 20

	// MaxSocketPath is sizeof(sockaddr_un.sun_path) on macOS minus the NUL.
	MaxSocketPath = 103
)

var vmIDRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// GatewayMAC is the helper's MAC on every VM's link (each VM has its own
// link, so one locally administered address is enough). The guest's MAC
// must differ.
var GatewayMAC = net.HardwareAddr{0x02, 0xc7, 0xe0, 0x00, 0x00, 0x01}

// ValidVMID reports whether id is safe to use as a directory name.
func ValidVMID(id string) bool { return vmIDRe.MatchString(id) }

// Limits bounds the sizes a VM may ask for. The daemon fills it from the
// host and Virtualization.framework.
type Limits struct {
	MinVCPUs, MaxVCPUs         int
	MinMemoryMiB, MaxMemoryMiB int
}

// Lease is the VM's /30, as allocated by the agent.
type Lease struct {
	Gateway string `json:"gateway"` // "10.200.0.1/30": the helper
	Guest   string `json:"guest"`   // "10.200.0.2/30": the guest
	MAC     string `json:"mac"`     // the guest NIC's MAC
}

// Config is vz.json.
type Config struct {
	VMID        string   `json:"vm_id"`
	VCPUs       int      `json:"vcpus"`
	MemoryMiB   int      `json:"memory_mib"`
	Kernel      string   `json:"kernel"`
	Cmdline     string   `json:"cmdline"`
	Disk        string   `json:"disk"`
	ConsoleLog  string   `json:"console_log"`
	GuestSocket string   `json:"guest_socket"`
	CtlSocket   string   `json:"ctl_socket"`
	ExitedPath  string   `json:"exited_path"`
	Lease       Lease    `json:"lease"`
	ServiceIP   string   `json:"service_ip,omitempty"`
	CacheAddr   string   `json:"cache_addr,omitempty"`
	DNSFallback string   `json:"dns_fallback,omitempty"`
	Site4       []string `json:"site4,omitempty"`
	MaxConns    int      `json:"max_conns,omitempty"`
	MTU         int      `json:"mtu,omitempty"`

	net Net
}

// Net is the parsed network view of a validated Config.
type Net struct {
	Gateway     netip.Addr
	Guest       netip.Addr
	GuestMAC    net.HardwareAddr
	ServiceIP   netip.Addr
	CacheAddr   netip.Addr     // invalid when unset
	DNSFallback netip.AddrPort // invalid when unset
	Site4       []netip.Prefix
	MaxConns    int
	MTU         int
}

// Load reads vz.json. It refuses symlinks and unknown fields but does not
// validate; call Validate or ValidateAt.
func Load(path string) (*Config, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file", path)
	}
	raw, err := io.ReadAll(io.LimitReader(f, MaxConfigBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > MaxConfigBytes {
		return nil, fmt.Errorf("%s: larger than %d bytes", path, MaxConfigBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var c Config
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if dec.More() {
		return nil, fmt.Errorf("parse %s: trailing data", path)
	}
	return &c, nil
}

// ValidateAt validates a config that was read from cfgPath, which must be
// <dataDir>/vms/<vm_id>/vz.json.
func (c *Config) ValidateAt(cfgPath, dataDir string, lim Limits) error {
	if !ValidVMID(c.VMID) {
		return fmt.Errorf("vm_id %q: must match %s", c.VMID, vmIDRe)
	}
	want := filepath.Join(dataDir, "vms", c.VMID, "vz.json")
	if filepath.Clean(cfgPath) != want {
		return fmt.Errorf("vm_id %q does not match the config's location %s", c.VMID, cfgPath)
	}
	return c.Validate(dataDir, lim)
}

// Validate checks every path and value, fills in defaults, and parses the
// network fields (see Net).
func (c *Config) Validate(dataDir string, lim Limits) error {
	if !filepath.IsAbs(dataDir) || filepath.Clean(dataDir) != dataDir {
		return fmt.Errorf("data dir %q must be absolute and clean", dataDir)
	}
	if !ValidVMID(c.VMID) {
		return fmt.Errorf("vm_id %q: must match %s", c.VMID, vmIDRe)
	}
	if c.VCPUs < lim.MinVCPUs || c.VCPUs > lim.MaxVCPUs {
		return fmt.Errorf("vcpus %d: must be between %d and %d", c.VCPUs, lim.MinVCPUs, lim.MaxVCPUs)
	}
	if c.MemoryMiB < lim.MinMemoryMiB || c.MemoryMiB > lim.MaxMemoryMiB {
		return fmt.Errorf("memory_mib %d: must be between %d and %d", c.MemoryMiB, lim.MinMemoryMiB, lim.MaxMemoryMiB)
	}
	if err := checkCmdline(c.Cmdline); err != nil {
		return err
	}
	if err := c.validatePaths(dataDir); err != nil {
		return err
	}
	return c.validateNet()
}

func checkCmdline(s string) error {
	if s == "" {
		return errors.New("cmdline: empty")
	}
	if len(s) > MaxCmdline {
		return fmt.Errorf("cmdline: %d bytes, at most %d", len(s), MaxCmdline)
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return fmt.Errorf("cmdline: byte %d is not printable ASCII", i)
		}
	}
	return nil
}

// leafKind says what a path must be, if it exists.
type leafKind int

const (
	mustBeFile     leafKind = iota // must exist, regular file
	fileIfExists                   // may be absent; regular file if present
	socketIfExists                 // may be absent; a socket if present
)

func (c *Config) validatePaths(dataDir string) error {
	vmDir := filepath.Join(dataDir, "vms", c.VMID)
	if err := noSymlinks(dataDir, vmDir, true); err != nil {
		return fmt.Errorf("vm dir: %w", err)
	}
	if st, err := os.Lstat(vmDir); err != nil {
		return fmt.Errorf("vm dir: %w", err)
	} else if !st.IsDir() {
		return fmt.Errorf("vm dir %s: not a directory", vmDir)
	}

	perVM := []struct {
		field, path string
		kind        leafKind
		socket      bool
	}{
		{"disk", c.Disk, mustBeFile, false},
		{"console_log", c.ConsoleLog, fileIfExists, false},
		{"guest_socket", c.GuestSocket, socketIfExists, true},
		{"ctl_socket", c.CtlSocket, socketIfExists, true},
		{"exited_path", c.ExitedPath, fileIfExists, false},
	}
	seen := map[string]string{}
	for _, p := range perVM {
		if err := checkUnder(p.path, vmDir); err != nil {
			return fmt.Errorf("%s: %w", p.field, err)
		}
		if filepath.Dir(p.path) != vmDir {
			return fmt.Errorf("%s %s: must be directly inside %s", p.field, p.path, vmDir)
		}
		if other, dup := seen[p.path]; dup {
			return fmt.Errorf("%s and %s: same path %s", other, p.field, p.path)
		}
		seen[p.path] = p.field
		if p.socket && len(p.path) > MaxSocketPath {
			return fmt.Errorf("%s %s: %d bytes, sockets allow at most %d", p.field, p.path, len(p.path), MaxSocketPath)
		}
		if err := checkLeaf(p.path, p.kind); err != nil {
			return fmt.Errorf("%s: %w", p.field, err)
		}
	}
	if filepath.Base(c.ExitedPath) != exitrec.FileName {
		return fmt.Errorf("exited_path %s: must be named %s", c.ExitedPath, exitrec.FileName)
	}
	if err := diskNotShared(c.Disk); err != nil {
		return fmt.Errorf("disk: %w", err)
	}

	if err := checkUnder(c.Kernel, dataDir); err != nil {
		return fmt.Errorf("kernel: %w", err)
	}
	if err := noSymlinks(dataDir, c.Kernel, false); err != nil {
		return fmt.Errorf("kernel: %w", err)
	}
	if err := checkLeaf(c.Kernel, mustBeFile); err != nil {
		return fmt.Errorf("kernel: %w", err)
	}
	if same, err := sameFile(c.Kernel, c.Disk); err != nil || same {
		return fmt.Errorf("kernel %s: is the disk", c.Kernel)
	}
	if err := checkArm64Image(c.Kernel); err != nil {
		return fmt.Errorf("kernel: %w", err)
	}
	return nil
}

// checkUnder requires p to be absolute, clean, free of ".." and strictly
// inside dir.
func checkUnder(p, dir string) error {
	if p == "" {
		return errors.New("empty path")
	}
	if !filepath.IsAbs(p) {
		return fmt.Errorf("%s: must be absolute", p)
	}
	for _, el := range strings.Split(p, string(filepath.Separator)) {
		if el == ".." || el == "." {
			return fmt.Errorf("%s: must not contain %q", p, el)
		}
	}
	if filepath.Clean(p) != p {
		return fmt.Errorf("%s: must be clean", p)
	}
	rel, err := filepath.Rel(dir, p)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return fmt.Errorf("%s: not under %s", p, dir)
	}
	return nil
}

// noSymlinks walks from root (trusted, may itself contain symlinks) down to
// p and fails if any component below root is a symlink. If includeLeaf is
// false the final component is left to checkLeaf.
func noSymlinks(root, p string, includeLeaf bool) error {
	rel, err := filepath.Rel(root, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return fmt.Errorf("%s: not under %s", p, root)
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if !includeLeaf {
		parts = parts[:len(parts)-1]
	}
	cur := root
	for _, el := range parts {
		cur = filepath.Join(cur, el)
		st, err := os.Lstat(cur)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("%s: %w", cur, err)
			}
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s: is a symlink", cur)
		}
	}
	return nil
}

func checkLeaf(p string, kind leafKind) error {
	st, err := os.Lstat(p)
	if errors.Is(err, os.ErrNotExist) && kind != mustBeFile {
		return nil
	}
	if err != nil {
		return fmt.Errorf("%s: %w", p, err)
	}
	if st.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s: is a symlink", p)
	}
	switch kind {
	case mustBeFile, fileIfExists:
		if !st.Mode().IsRegular() {
			return fmt.Errorf("%s: not a regular file", p)
		}
	case socketIfExists:
		if st.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("%s: exists and is not a socket", p)
		}
	}
	return nil
}

// diskNotShared refuses a disk with more than one hard link: a clone made
// with clonefile(2) has exactly one, and a hard link could alias an image
// or another VM's disk.
func diskNotShared(p string) error {
	st, err := os.Lstat(p)
	if err != nil {
		return err
	}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok && sys.Nlink > 1 {
		return fmt.Errorf("%s: has %d hard links, want 1", p, sys.Nlink)
	}
	if st.Size() == 0 {
		return fmt.Errorf("%s: empty", p)
	}
	return nil
}

func sameFile(a, b string) (bool, error) {
	sa, err := os.Stat(a)
	if err != nil {
		return false, err
	}
	sb, err := os.Stat(b)
	if err != nil {
		return false, err
	}
	return os.SameFile(sa, sb), nil
}

// checkArm64Image checks for the arm64 Linux Image header magic ("ARM\x64"
// at 0x38). VZLinuxBootLoader needs an uncompressed Image; a gzip'd vmlinuz
// fails later with a far less useful error.
func checkArm64Image(p string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	var hdr [64]byte
	if _, err := io.ReadFull(f, hdr[:]); err != nil {
		return fmt.Errorf("%s: too short for an arm64 Image", p)
	}
	if binary.LittleEndian.Uint32(hdr[0x38:]) != 0x644d5241 {
		return fmt.Errorf("%s: not an uncompressed arm64 Image (no ARM\\x64 magic)", p)
	}
	return nil
}

func (c *Config) validateNet() error {
	var n Net
	gw, err := netip.ParsePrefix(c.Lease.Gateway)
	if err != nil || !gw.Addr().Is4() || gw.Bits() != 30 {
		return fmt.Errorf("lease.gateway %q: want an IPv4 /30 such as 10.200.0.1/30", c.Lease.Gateway)
	}
	guest, err := netip.ParsePrefix(c.Lease.Guest)
	if err != nil || !guest.Addr().Is4() || guest.Bits() != 30 {
		return fmt.Errorf("lease.guest %q: want an IPv4 /30 such as 10.200.0.2/30", c.Lease.Guest)
	}
	base := gw.Masked().Addr()
	if guest.Masked().Addr() != base {
		return fmt.Errorf("lease: gateway %s and guest %s are in different /30s", gw, guest)
	}
	if gw.Addr() != base.Next() || guest.Addr() != base.Next().Next() {
		return fmt.Errorf("lease: gateway must be .1 and guest .2 of %s", gw.Masked())
	}
	n.Gateway, n.Guest = gw.Addr(), guest.Addr()

	mac, err := net.ParseMAC(c.Lease.MAC)
	if err != nil || len(mac) != 6 {
		return fmt.Errorf("lease.mac %q: want a 48-bit MAC", c.Lease.MAC)
	}
	if mac[0]&1 != 0 {
		return fmt.Errorf("lease.mac %q: multicast", c.Lease.MAC)
	}
	if bytes.Equal(mac, GatewayMAC) {
		return fmt.Errorf("lease.mac %q: is the gateway's MAC", c.Lease.MAC)
	}
	n.GuestMAC = mac

	if c.ServiceIP == "" {
		c.ServiceIP = DefaultServiceIP
	}
	svc, err := netip.ParseAddr(c.ServiceIP)
	if err != nil || !svc.Is4() || !unicast(svc) {
		return fmt.Errorf("service_ip %q: want a unicast IPv4 address", c.ServiceIP)
	}
	if gw.Masked().Contains(svc) {
		return fmt.Errorf("service_ip %s: inside the lease %s", svc, gw.Masked())
	}
	n.ServiceIP = svc

	if c.CacheAddr != "" {
		a, err := netip.ParseAddr(c.CacheAddr)
		if err != nil || !a.Is4() || !unicast(a) || a.IsLoopback() {
			return fmt.Errorf("cache_addr %q: want a non-loopback unicast IPv4 address, without a port", c.CacheAddr)
		}
		if a == svc || gw.Masked().Contains(a) {
			return fmt.Errorf("cache_addr %s: is the service address or inside the lease", a)
		}
		n.CacheAddr = a
	}

	if c.DNSFallback != "" {
		ap, err := netip.ParseAddrPort(c.DNSFallback)
		if err != nil {
			a, err2 := netip.ParseAddr(c.DNSFallback)
			if err2 != nil {
				return fmt.Errorf("dns_fallback %q: want ip or ip:port", c.DNSFallback)
			}
			ap = netip.AddrPortFrom(a, 53)
		}
		a := ap.Addr()
		if !a.Is4() || !unicast(a) || a.IsLoopback() || ap.Port() == 0 {
			return fmt.Errorf("dns_fallback %q: want a non-loopback unicast IPv4 address", c.DNSFallback)
		}
		if a == svc || gw.Masked().Contains(a) {
			return fmt.Errorf("dns_fallback %s: is the service address or inside the lease", a)
		}
		n.DNSFallback = ap
	}

	if len(c.Site4) > MaxSite4 {
		return fmt.Errorf("site4: %d entries, at most %d", len(c.Site4), MaxSite4)
	}
	for _, s := range c.Site4 {
		p, err := netip.ParsePrefix(s)
		if err != nil {
			a, err2 := netip.ParseAddr(s)
			if err2 != nil {
				return fmt.Errorf("site4 %q: want an IPv4 CIDR", s)
			}
			p = netip.PrefixFrom(a, a.BitLen())
		}
		if !p.Addr().Is4() {
			return fmt.Errorf("site4 %q: IPv4 only", s)
		}
		n.Site4 = append(n.Site4, p.Masked())
	}

	switch {
	case c.MaxConns == 0:
		c.MaxConns = DefaultMaxConns
	case c.MaxConns < 0 || c.MaxConns > MaxMaxConns:
		return fmt.Errorf("max_conns %d: must be between 1 and %d", c.MaxConns, MaxMaxConns)
	}
	n.MaxConns = c.MaxConns

	switch {
	case c.MTU == 0:
		c.MTU = DefaultMTU
	case c.MTU < MinMTU || c.MTU > MaxMTU:
		return fmt.Errorf("mtu %d: must be between %d and %d", c.MTU, MinMTU, MaxMTU)
	}
	n.MTU = c.MTU

	c.net = n
	return nil
}

func unicast(a netip.Addr) bool {
	return a.IsValid() && !a.IsUnspecified() && !a.IsMulticast() &&
		a != netip.AddrFrom4([4]byte{255, 255, 255, 255})
}

// Net returns the parsed network fields. Only valid after Validate.
func (c *Config) Net() Net { return c.net }

// VMDir is the VM's own directory: the one holding its per-VM files.
func (c *Config) VMDir() string { return filepath.Dir(c.ExitedPath) }
