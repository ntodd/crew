package vmctl

import (
	"bytes"
	"encoding/json"
)

// The agent writes vms/<vm_id>/fc.json in Firecracker's own format, with
// host paths and the size's rate limiters (§11.3). crew-vmctl decodes it
// against the subset of the schema Crew uses (anything else is refused),
// checks every value against vm.json and fixed bounds, and writes the
// chroot's fc.json from what it checked: chroot paths, and its own
// logger and metrics.

type fcConfig struct {
	BootSource        bootSource  `json:"boot-source"`
	Drives            []drive     `json:"drives"`
	MachineConfig     machineConf `json:"machine-config"`
	NetworkInterfaces []netIface  `json:"network-interfaces"`
	Entropy           *entropy    `json:"entropy"`
	Logger            *fcLogger   `json:"logger,omitempty"`
	Metrics           *fcMetrics  `json:"metrics,omitempty"`
}

type bootSource struct {
	KernelImagePath string `json:"kernel_image_path"`
	BootArgs        string `json:"boot_args"`
}

type drive struct {
	DriveID      string       `json:"drive_id"`
	PathOnHost   string       `json:"path_on_host"`
	IsRootDevice bool         `json:"is_root_device"`
	IsReadOnly   bool         `json:"is_read_only"`
	RateLimiter  *rateLimiter `json:"rate_limiter,omitempty"`
}

type machineConf struct {
	VCPUCount  int  `json:"vcpu_count"`
	MemSizeMiB int  `json:"mem_size_mib"`
	SMT        bool `json:"smt"`
}

type netIface struct {
	IfaceID       string       `json:"iface_id"`
	HostDevName   string       `json:"host_dev_name"`
	GuestMAC      string       `json:"guest_mac"`
	RxRateLimiter *rateLimiter `json:"rx_rate_limiter,omitempty"`
	TxRateLimiter *rateLimiter `json:"tx_rate_limiter,omitempty"`
}

type rateLimiter struct {
	Bandwidth *tokenBucket `json:"bandwidth,omitempty"`
	Ops       *tokenBucket `json:"ops,omitempty"`
}

type tokenBucket struct {
	Size         int64  `json:"size"`
	OneTimeBurst *int64 `json:"one_time_burst,omitempty"`
	RefillTime   int64  `json:"refill_time"`
}

type entropy struct {
	RateLimiter *rateLimiter `json:"rate_limiter,omitempty"`
}

type fcLogger struct {
	LogPath       string `json:"log_path"`
	Level         string `json:"level"`
	ShowLevel     bool   `json:"show_level"`
	ShowLogOrigin bool   `json:"show_log_origin"`
}

type fcMetrics struct {
	MetricsPath string `json:"metrics_path"`
}

// Bounds on rate limiters: a bucket holds at most 1 TiB (or 2^40 ops)
// and refills in 1 ms to a minute.
const (
	maxBucket     = int64(1) << 40
	maxRefillMs   = 60_000
	maxBootArgs   = 2048 // the kernel's COMMAND_LINE_SIZE on arm64 and x86
	chrootKernel  = "/kernel"
	chrootRootfs  = "/rootfs.ext4"
	chrootLog     = "/fc.log"
	chrootMetrics = "/fc.metrics"
)

// ChrootConfig checks the agent's fc.json against vm and returns the
// chroot's fc.json.
func ChrootConfig(body []byte, vm VM, p Paths) ([]byte, error) {
	if len(body) > MaxFile {
		return nil, fail(ErrInvalidConfig, "fc.json is over %d bytes", MaxFile)
	}
	var c fcConfig
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fail(ErrInvalidConfig, "fc.json: %v", err)
	}
	if dec.More() {
		return nil, fail(ErrInvalidConfig, "fc.json: trailing data")
	}
	if err := check(&c, vm, p); err != nil {
		return nil, err
	}

	c.BootSource.KernelImagePath = chrootKernel
	c.Drives[0].PathOnHost = chrootRootfs
	c.Logger = &fcLogger{LogPath: chrootLog, Level: "Warning", ShowLevel: true}
	c.Metrics = &fcMetrics{MetricsPath: chrootMetrics}
	out, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

func check(c *fcConfig, vm VM, p Paths) error {
	bad := func(format string, a ...any) error {
		return fail(ErrInvalidConfig, "fc.json: "+format, a...)
	}
	if c.BootSource.KernelImagePath != p.Kernel(vm.ImageID) {
		return bad("the kernel must be %s", p.Kernel(vm.ImageID))
	}
	if err := checkBootArgs(c.BootSource.BootArgs); err != nil {
		return bad("%v", err)
	}

	if len(c.Drives) != 1 {
		return bad("exactly one drive, the clone")
	}
	d := c.Drives[0]
	switch {
	case d.DriveID != "rootfs":
		return bad("the drive is rootfs")
	case d.PathOnHost != p.Clone(vm.ID):
		return bad("the drive must be %s", p.Clone(vm.ID))
	case !d.IsRootDevice || d.IsReadOnly:
		return bad("the clone is the read-write root device")
	}
	if err := checkLimiter(d.RateLimiter); err != nil {
		return bad("drive: %v", err)
	}

	m := c.MachineConfig
	switch {
	case m.VCPUCount != vm.VCPUs:
		return bad("vcpu_count must be the size's %d", vm.VCPUs)
	case m.MemSizeMiB != vm.MemoryMiB:
		return bad("mem_size_mib must be the size's %d", vm.MemoryMiB)
	case m.SMT:
		return bad("smt must be false")
	}

	if len(c.NetworkInterfaces) != 1 {
		return bad("exactly one network interface")
	}
	n := c.NetworkInterfaces[0]
	switch {
	case n.IfaceID != "eth0":
		return bad("the interface is eth0")
	case n.HostDevName != vm.Lease.Tap:
		return bad("the interface must be on the lease's tap, %s", vm.Lease.Tap)
	case n.GuestMAC != vm.Lease.MAC:
		return bad("the MAC must be the lease's, %s", vm.Lease.MAC)
	}
	for _, l := range []*rateLimiter{n.RxRateLimiter, n.TxRateLimiter} {
		if err := checkLimiter(l); err != nil {
			return bad("network: %v", err)
		}
	}

	if c.Entropy == nil {
		return bad("the VM gets a virtio-rng device (entropy)")
	}
	if err := checkLimiter(c.Entropy.RateLimiter); err != nil {
		return bad("entropy: %v", err)
	}
	if c.Logger != nil || c.Metrics != nil {
		return bad("the logger and metrics are crew-vmctl's to set")
	}
	return nil
}

func checkBootArgs(s string) error {
	if len(s) == 0 || len(s) > maxBootArgs {
		return fail(ErrInvalidConfig, "boot_args must be 1 to %d bytes", maxBootArgs)
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return fail(ErrInvalidConfig, "boot_args must be printable ASCII")
		}
	}
	return nil
}

func checkLimiter(l *rateLimiter) error {
	if l == nil {
		return nil
	}
	if l.Bandwidth == nil && l.Ops == nil {
		return fail(ErrInvalidConfig, "a rate limiter needs a bucket")
	}
	for _, b := range []*tokenBucket{l.Bandwidth, l.Ops} {
		if b == nil {
			continue
		}
		if b.Size < 1 || b.Size > maxBucket {
			return fail(ErrInvalidConfig, "bucket size must be 1 to %d", maxBucket)
		}
		if b.RefillTime < 1 || b.RefillTime > maxRefillMs {
			return fail(ErrInvalidConfig, "refill_time must be 1 to %d ms", maxRefillMs)
		}
		if b.OneTimeBurst != nil && (*b.OneTimeBurst < 0 || *b.OneTimeBurst > maxBucket) {
			return fail(ErrInvalidConfig, "one_time_burst must be 0 to %d", maxBucket)
		}
	}
	return nil
}
