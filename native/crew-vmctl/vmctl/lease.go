package vmctl

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"strconv"
)

// UIDBase is the first VM uid and gid: a VM's are UIDBase + its lease
// index (§11.3), unique among live VMs because leases are.
const UIDBase = 200000

// VMNet is the range VM links come from (§14.1, CREW_VM_NET): one /30
// per lease, .1 the gateway on the tap and .2 the guest. Lease n is the
// n-th /30; lease 0 is never used.
type VMNet struct {
	prefix netip.Prefix
}

// Lease is everything crew-vmctl derives from a lease index. Nothing
// here comes from the agent but the index.
type Lease struct {
	Index   int
	Tap     string // crewt<index>
	UID     int
	GID     int
	Gateway string
	Guest   string
	MAC     string // 02:c2 and the guest's address, as CrewAgent.Net has it
}

// The ranges a VM network may be in: private space only, so it can never
// shadow the uplink's routes to the internet.
var privateRanges = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("100.64.0.0/10"),
}

// ParseVMNet parses an IPv4 CIDR between /16 (16,384 leases, so uids
// stay under 216,384 and tap names under IFNAMSIZ) and /28.
func ParseVMNet(cidr string) (VMNet, error) {
	p, err := netip.ParsePrefix(cidr)
	if err != nil || !p.Addr().Is4() {
		return VMNet{}, fmt.Errorf("VM network %q: not an IPv4 CIDR", cidr)
	}
	if p.Masked() != p || p.String() != cidr {
		return VMNet{}, fmt.Errorf("VM network %q: not in canonical form", cidr)
	}
	if p.Bits() < 16 || p.Bits() > 28 {
		return VMNet{}, fmt.Errorf("VM network %q: the prefix must be /16 to /28", cidr)
	}
	for _, r := range privateRanges {
		if r.Contains(p.Addr()) && r.Bits() <= p.Bits() {
			return VMNet{prefix: p}, nil
		}
	}
	return VMNet{}, fmt.Errorf("VM network %q: not in private address space", cidr)
}

// Capacity is the number of /30s in the range, lease 0 included.
func (n VMNet) Capacity() int { return 1 << (32 - n.prefix.Bits() - 2) }

func (n VMNet) String() string { return n.prefix.String() }

// Lease derives lease index's tap, ids and addresses. The index must be
// 1 to Capacity()-1.
func (n VMNet) Lease(index int) (Lease, error) {
	if index < 1 || index >= n.Capacity() {
		return Lease{}, fmt.Errorf("lease index %d: must be 1 to %d", index, n.Capacity()-1)
	}
	base := n.prefix.Addr().As4()
	network := binary.BigEndian.Uint32(base[:]) + uint32(index)*4
	addr := func(off uint32) netip.Addr {
		var b [4]byte
		binary.BigEndian.PutUint32(b[:], network+off)
		return netip.AddrFrom4(b)
	}
	guest := addr(2).As4()
	return Lease{
		Index:   index,
		Tap:     "crewt" + strconv.Itoa(index),
		UID:     UIDBase + index,
		GID:     UIDBase + index,
		Gateway: addr(1).String(),
		Guest:   addr(2).String(),
		MAC:     fmt.Sprintf("02:c2:%02x:%02x:%02x:%02x", guest[0], guest[1], guest[2], guest[3]),
	}, nil
}
