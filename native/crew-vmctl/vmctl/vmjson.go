package vmctl

import (
	"bytes"
	"encoding/json"
	"time"
)

// MaxFile is the largest vm.json or fc.json crew-vmctl reads.
const MaxFile = 64 << 10

// Bounds on what a VM may be given. Sizes are checked by the control
// plane and the agent too (§7.1); these hold even if both are wrong.
const (
	MaxVCPUs     = 32
	MinMemoryMiB = 1024
	MaxMemoryMiB = 1 << 20 // 1 TiB
	MaxLifetime  = 7 * 24 * time.Hour
)

// BootMiB is the memory a VM of this size boots with: its size plus what
// the guest kernel keeps, so the guest's MemTotal is the size (§11.6 item
// 2). The same formula as CrewProtocol.GuestMemory.boot_mib/1.
func BootMiB(memoryMiB int) int { return memoryMiB + 48 + memoryMiB*37/2000 }

// VM is what crew-vmctl takes from vm.json.
type VM struct {
	ID        string
	ImageID   string
	VCPUs     int
	MemoryMiB int
	Deadline  time.Time
	Lease     Lease
}

type vmRecord struct {
	VMID  string `json:"vm_id"`
	Image struct {
		ID string `json:"id"`
	} `json:"image"`
	Size struct {
		VCPUs     int `json:"vcpus"`
		MemoryMiB int `json:"memory_mib"`
	} `json:"size"`
	Deadline   int64 `json:"deadline"`
	LeaseIndex int   `json:"lease_index"`
}

// ParseVM reads the agent's vm.json for vmID. It carries more than this
// (the agent's own bookkeeping), which is ignored; what's used is checked.
func ParseVM(body []byte, vmID string, net VMNet, now time.Time) (VM, error) {
	if len(body) > MaxFile {
		return VM{}, fail(ErrInvalidConfig, "vm.json is over %d bytes", MaxFile)
	}
	var r vmRecord
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&r); err != nil {
		return VM{}, fail(ErrInvalidConfig, "vm.json: %v", err)
	}
	switch {
	case r.VMID != vmID:
		return VM{}, fail(ErrInvalidConfig, "vm.json is another VM's")
	case !IsUUID(r.Image.ID):
		return VM{}, fail(ErrInvalidConfig, "vm.json: image.id must be a UUID")
	case !validVCPUs(r.Size.VCPUs):
		return VM{}, fail(ErrInvalidConfig, "vm.json: vcpus must be 1 or even, up to %d", MaxVCPUs)
	case r.Size.MemoryMiB < MinMemoryMiB || r.Size.MemoryMiB > MaxMemoryMiB:
		return VM{}, fail(ErrInvalidConfig, "vm.json: memory_mib must be %d to %d", MinMemoryMiB, MaxMemoryMiB)
	}
	deadline := time.Unix(r.Deadline, 0)
	if !deadline.After(now) {
		return VM{}, fail(ErrInvalidConfig, "vm.json: the deadline has passed")
	}
	if deadline.Sub(now) > MaxLifetime {
		return VM{}, fail(ErrInvalidConfig, "vm.json: the deadline is more than %s away", MaxLifetime)
	}
	lease, err := net.Lease(r.LeaseIndex)
	if err != nil {
		return VM{}, fail(ErrInvalidConfig, "vm.json: %v", err)
	}
	return VM{ID: vmID, ImageID: r.Image.ID, VCPUs: r.Size.VCPUs, MemoryMiB: r.Size.MemoryMiB,
		Deadline: deadline, Lease: lease}, nil
}

// Firecracker's rule, and §7.1's.
func validVCPUs(n int) bool { return n == 1 || (n >= 2 && n <= MaxVCPUs && n%2 == 0) }
