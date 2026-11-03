package netstack

import (
	"encoding/binary"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"
)

// This file is the guest's whole layer 2: every frame from the guest goes
// through Ingress before anything else sees it, and every frame to the guest
// is built by Egress or by an Ingress reply. The guest sees exactly one
// neighbour, the gateway, and gVisor never sees ARP, IPv6 or ICMP.

const (
	etherTypeIPv4 = 0x0800
	etherTypeARP  = 0x0806
	etherTypeIPv6 = 0x86dd
	ethHeaderLen  = 14

	protoICMP = 1
	protoTCP  = 6
	protoUDP  = 17

	icmpEchoReply   = 0
	icmpEchoRequest = 8
)

// Verdict is what to do with a frame from the guest.
type Verdict int

const (
	Drop    Verdict = iota
	Deliver         // Result.Packet is an IPv4 packet for the stack
	Reply           // Result.Packet is a frame to send back to the guest
)

func (v Verdict) String() string {
	switch v {
	case Drop:
		return "drop"
	case Deliver:
		return "deliver"
	case Reply:
		return "reply"
	}
	return "?"
}

// DropReason says why a frame was dropped. Counters are kept per reason.
type DropReason int

const (
	DropNone          DropReason = iota
	DropMalformed                // runt frame, bad IPv4 header
	DropIPv6                     // any IPv6
	DropEtherType                // anything but IPv4 and ARP (VLAN, LLDP, ...)
	DropARP                      // ARP that isn't a request for the gateway
	DropNotForGateway            // IPv4 not addressed to the gateway's MAC
	DropSpoofed                  // source isn't the guest's lease address
	DropBroadcast                // broadcast or multicast destination
	DropProtocol                 // not TCP, UDP or ICMP
	DropICMP                     // ICMP other than echo to the host
	DropRateLimited              // echo over 10/s
	numDropReasons
)

var dropNames = [numDropReasons]string{
	"none", "malformed", "ipv6", "ethertype", "arp", "not_for_gateway",
	"spoofed", "broadcast", "protocol", "icmp", "rate_limited",
}

func (r DropReason) String() string {
	if r >= 0 && r < numDropReasons {
		return dropNames[r]
	}
	return "unknown"
}

// Result is the outcome of Ingress.
type Result struct {
	Verdict Verdict
	Packet  []byte
	Reason  DropReason
}

// L2Config describes the VM's link.
type L2Config struct {
	GatewayMAC net.HardwareAddr
	GuestMAC   net.HardwareAddr
	Gateway    netip.Addr // .1 of the lease
	Guest      netip.Addr // .2 of the lease
	ServiceIP  netip.Addr
	// EchoPerSecond limits echo replies (burst of the same size). 0 means 10.
	EchoPerSecond int
	Now           func() time.Time
}

// L2 is the per-VM link-layer filter.
type L2 struct {
	gwMAC, guestMAC [6]byte
	gw, guest, svc  [4]byte
	subnet          netip.Prefix
	echo            tokenBucket
	drops           [numDropReasons]atomic.Uint64
}

func NewL2(c L2Config) *L2 {
	l := &L2{
		gw:     c.Gateway.As4(),
		guest:  c.Guest.As4(),
		svc:    c.ServiceIP.As4(),
		subnet: netip.PrefixFrom(c.Gateway, 30).Masked(),
	}
	copy(l.gwMAC[:], c.GatewayMAC)
	copy(l.guestMAC[:], c.GuestMAC)
	rate := c.EchoPerSecond
	if rate <= 0 {
		rate = 10
	}
	now := c.Now
	if now == nil {
		now = time.Now
	}
	l.echo = tokenBucket{rate: float64(rate), burst: float64(rate), tokens: float64(rate), now: now}
	return l
}

func (l *L2) drop(r DropReason) Result {
	l.drops[r].Add(1)
	return Result{Verdict: Drop, Reason: r}
}

// Drops returns the drop counters by reason (non-zero ones only).
func (l *L2) Drops() map[DropReason]uint64 {
	out := map[DropReason]uint64{}
	for i := DropReason(1); i < numDropReasons; i++ {
		if n := l.drops[i].Load(); n > 0 {
			out[i] = n
		}
	}
	return out
}

// Ingress classifies one frame from the guest. A Deliver result aliases
// frame; a Reply result is a new buffer.
func (l *L2) Ingress(frame []byte) Result {
	if len(frame) < ethHeaderLen {
		return l.drop(DropMalformed)
	}
	switch binary.BigEndian.Uint16(frame[12:14]) {
	case etherTypeARP:
		return l.arp(frame)
	case etherTypeIPv4:
		return l.ipv4(frame)
	case etherTypeIPv6:
		return l.drop(DropIPv6)
	default:
		return l.drop(DropEtherType)
	}
}

func (l *L2) arp(frame []byte) Result {
	a := frame[ethHeaderLen:]
	if len(a) < 28 ||
		binary.BigEndian.Uint16(a[0:2]) != 1 || // ethernet
		binary.BigEndian.Uint16(a[2:4]) != etherTypeIPv4 ||
		a[4] != 6 || a[5] != 4 ||
		binary.BigEndian.Uint16(a[6:8]) != 1 { // request
		return l.drop(DropARP)
	}
	if [4]byte(a[14:18]) != l.guest || [4]byte(a[24:28]) != l.gw {
		return l.drop(DropARP)
	}
	var requester [6]byte
	copy(requester[:], a[8:14])

	out := make([]byte, ethHeaderLen+28)
	copy(out[0:6], requester[:])
	copy(out[6:12], l.gwMAC[:])
	binary.BigEndian.PutUint16(out[12:14], etherTypeARP)
	r := out[ethHeaderLen:]
	binary.BigEndian.PutUint16(r[0:2], 1)
	binary.BigEndian.PutUint16(r[2:4], etherTypeIPv4)
	r[4], r[5] = 6, 4
	binary.BigEndian.PutUint16(r[6:8], 2) // reply
	copy(r[8:14], l.gwMAC[:])
	copy(r[14:18], l.gw[:])
	copy(r[18:24], requester[:])
	copy(r[24:28], l.guest[:])
	return Result{Verdict: Reply, Packet: out}
}

func (l *L2) ipv4(frame []byte) Result {
	if [6]byte(frame[0:6]) != l.gwMAC {
		return l.drop(DropNotForGateway)
	}
	p := frame[ethHeaderLen:]
	if len(p) < 20 || p[0]>>4 != 4 {
		return l.drop(DropMalformed)
	}
	ihl := int(p[0]&0x0f) * 4
	total := int(binary.BigEndian.Uint16(p[2:4]))
	if ihl < 20 || total < ihl || total > len(p) {
		return l.drop(DropMalformed)
	}
	p = p[:total] // strip ethernet padding
	if [4]byte(p[12:16]) != l.guest {
		return l.drop(DropSpoofed)
	}
	dst := netip.AddrFrom4([4]byte(p[16:20]))
	if dst.IsMulticast() || dst == netip.AddrFrom4([4]byte{255, 255, 255, 255}) ||
		dst == l.subnet.Addr() || dst == broadcastOf(l.subnet) {
		return l.drop(DropBroadcast)
	}
	switch p[9] {
	case protoTCP, protoUDP:
		return Result{Verdict: Deliver, Packet: p}
	case protoICMP:
		return l.icmp(p, ihl)
	default:
		return l.drop(DropProtocol)
	}
}

func broadcastOf(p netip.Prefix) netip.Addr {
	a := p.Addr().As4()
	a[3] |= 0x03
	return netip.AddrFrom4(a)
}

// icmp answers echo requests to the service address and the gateway, and
// drops every other ICMP message. Echo is never forwarded.
func (l *L2) icmp(p []byte, ihl int) Result {
	fragmented := binary.BigEndian.Uint16(p[6:8])&0x3fff != 0 // MF or offset
	ic := p[ihl:]
	if fragmented || len(ic) < 8 || ic[0] != icmpEchoRequest || ic[1] != 0 || checksum(ic, 0) != 0 {
		return l.drop(DropICMP)
	}
	dst := [4]byte(p[16:20])
	if dst != l.svc && dst != l.gw {
		return l.drop(DropICMP)
	}
	if !l.echo.take() {
		return l.drop(DropRateLimited)
	}

	out := make([]byte, ethHeaderLen+20+len(ic))
	copy(out[0:6], l.guestMAC[:])
	copy(out[6:12], l.gwMAC[:])
	binary.BigEndian.PutUint16(out[12:14], etherTypeIPv4)
	ip := out[ethHeaderLen:]
	ip[0] = 0x45
	binary.BigEndian.PutUint16(ip[2:4], uint16(20+len(ic)))
	ip[8] = 64
	ip[9] = protoICMP
	copy(ip[12:16], dst[:])
	copy(ip[16:20], l.guest[:])
	binary.BigEndian.PutUint16(ip[10:12], checksum(ip[:20], 0))
	r := ip[20:]
	copy(r, ic)
	r[0] = icmpEchoReply
	r[2], r[3] = 0, 0
	binary.BigEndian.PutUint16(r[2:4], checksum(r, 0))
	return Result{Verdict: Reply, Packet: out}
}

// Egress frames an IPv4 packet from the stack for the guest, appending to
// dst. It refuses anything that isn't IPv4 addressed to the guest.
func (l *L2) Egress(dst, pkt []byte) ([]byte, bool) {
	start := len(dst)
	dst = append(dst, make([]byte, ethHeaderLen)...)
	dst = append(dst, pkt...)
	if !l.frameInPlace(dst[start:]) {
		return dst[:start], false
	}
	return dst, true
}

// frameInPlace fills in the ethernet header of f, whose first 14 bytes are
// reserved and the rest is an IPv4 packet. It reports false (and the frame
// must not be sent) unless the packet is IPv4 addressed to the guest.
func (l *L2) frameInPlace(f []byte) bool {
	p := f[ethHeaderLen:]
	if len(p) < 20 || p[0]>>4 != 4 || [4]byte(p[16:20]) != l.guest {
		return false
	}
	copy(f[0:6], l.guestMAC[:])
	copy(f[6:12], l.gwMAC[:])
	binary.BigEndian.PutUint16(f[12:14], etherTypeIPv4)
	return true
}

// checksum is the Internet checksum (RFC 1071) of b, folded with initial.
// Checking a block that contains its own checksum yields 0.
func checksum(b []byte, initial uint32) uint16 {
	sum := initial
	for len(b) >= 2 {
		sum += uint32(b[0])<<8 | uint32(b[1])
		b = b[2:]
	}
	if len(b) == 1 {
		sum += uint32(b[0]) << 8
	}
	for sum>>16 != 0 {
		sum = sum&0xffff + sum>>16
	}
	return ^uint16(sum)
}

// tokenBucket is a small rate limiter with an injectable clock.
type tokenBucket struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

func (b *tokenBucket) take() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	if !b.last.IsZero() {
		b.tokens += now.Sub(b.last).Seconds() * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
