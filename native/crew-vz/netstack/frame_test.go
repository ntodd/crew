package netstack

import (
	"bytes"
	"encoding/binary"
	"net"
	"net/netip"
	"testing"
	"time"
)

var (
	gwMAC    = net.HardwareAddr{0x02, 0xc7, 0xe0, 0x00, 0x00, 0x01}
	guestMAC = net.HardwareAddr{0x02, 0x00, 0x0a, 0xc8, 0x00, 0x02}
	bcastMAC = net.HardwareAddr{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
	gwIP     = netip.MustParseAddr("10.200.0.1")
	guestIP  = netip.MustParseAddr("10.200.0.2")
	svcIP    = netip.MustParseAddr("10.199.0.1")
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func newTestL2() (*L2, *fakeClock) {
	clk := &fakeClock{t: time.Unix(1_800_000_000, 0)}
	l := NewL2(L2Config{
		GatewayMAC: gwMAC, GuestMAC: guestMAC,
		Gateway: gwIP, Guest: guestIP, ServiceIP: svcIP,
		EchoPerSecond: 10,
		Now:           clk.now,
	})
	return l, clk
}

func eth(dst, src net.HardwareAddr, etherType uint16, payload []byte) []byte {
	f := make([]byte, 14+len(payload))
	copy(f[0:6], dst)
	copy(f[6:12], src)
	binary.BigEndian.PutUint16(f[12:14], etherType)
	copy(f[14:], payload)
	return f
}

func arpPkt(op uint16, sha net.HardwareAddr, spa netip.Addr, tha net.HardwareAddr, tpa netip.Addr) []byte {
	p := make([]byte, 28)
	binary.BigEndian.PutUint16(p[0:2], 1)      // ethernet
	binary.BigEndian.PutUint16(p[2:4], 0x0800) // IPv4
	p[4], p[5] = 6, 4
	binary.BigEndian.PutUint16(p[6:8], op)
	copy(p[8:14], sha)
	s := spa.As4()
	copy(p[14:18], s[:])
	copy(p[18:24], tha)
	d := tpa.As4()
	copy(p[24:28], d[:])
	return p
}

type ipOpts struct {
	flagsFrag uint16
	ihl       int
	version   int
	totalLen  int
}

func ip4pkt(src, dst netip.Addr, proto uint8, payload []byte, o ipOpts) []byte {
	ihl := 5
	if o.ihl != 0 {
		ihl = o.ihl
	}
	hl := ihl * 4
	p := make([]byte, hl+len(payload))
	ver := 4
	if o.version != 0 {
		ver = o.version
	}
	p[0] = byte(ver<<4 | ihl)
	tl := len(p)
	if o.totalLen != 0 {
		tl = o.totalLen
	}
	binary.BigEndian.PutUint16(p[2:4], uint16(tl))
	binary.BigEndian.PutUint16(p[6:8], o.flagsFrag)
	p[8] = 64
	p[9] = proto
	s, d := src.As4(), dst.As4()
	copy(p[12:16], s[:])
	copy(p[16:20], d[:])
	binary.BigEndian.PutUint16(p[10:12], checksum(p[:hl], 0))
	copy(p[hl:], payload)
	return p
}

func icmpEcho(typ uint8, id, seq uint16, data []byte) []byte {
	p := make([]byte, 8+len(data))
	p[0] = typ
	binary.BigEndian.PutUint16(p[4:6], id)
	binary.BigEndian.PutUint16(p[6:8], seq)
	copy(p[8:], data)
	binary.BigEndian.PutUint16(p[2:4], checksum(p, 0))
	return p
}

func tcpSyn(srcPort, dstPort uint16) []byte {
	p := make([]byte, 20)
	binary.BigEndian.PutUint16(p[0:2], srcPort)
	binary.BigEndian.PutUint16(p[2:4], dstPort)
	p[12] = 5 << 4
	p[13] = 0x02
	return p
}

func expectDrop(t *testing.T, l *L2, frame []byte, reason DropReason) {
	t.Helper()
	r := l.Ingress(frame)
	if r.Verdict != Drop {
		t.Fatalf("verdict = %v, want drop (%v)", r.Verdict, reason)
	}
	if r.Reason != reason {
		t.Fatalf("drop reason = %v, want %v", r.Reason, reason)
	}
}

func TestRuntAndUnknownEtherTypes(t *testing.T) {
	l, _ := newTestL2()
	expectDrop(t, l, []byte{1, 2, 3}, DropMalformed)
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x86dd, make([]byte, 40)), DropIPv6)
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x8100, make([]byte, 40)), DropEtherType) // VLAN
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x88cc, make([]byte, 40)), DropEtherType) // LLDP
	if got := l.Drops()[DropIPv6]; got != 1 {
		t.Fatalf("ipv6 drop counter = %d", got)
	}
}

func TestARPForGatewayIsAnswered(t *testing.T) {
	l, _ := newTestL2()
	req := eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, guestIP, make(net.HardwareAddr, 6), gwIP))
	r := l.Ingress(req)
	if r.Verdict != Reply {
		t.Fatalf("verdict = %v (%v), want reply", r.Verdict, r.Reason)
	}
	f := r.Packet
	if !bytes.Equal(f[0:6], guestMAC) || !bytes.Equal(f[6:12], gwMAC) || binary.BigEndian.Uint16(f[12:14]) != 0x0806 {
		t.Fatalf("bad ethernet header % x", f[:14])
	}
	a := f[14:]
	if binary.BigEndian.Uint16(a[6:8]) != 2 {
		t.Fatal("not an ARP reply")
	}
	if !bytes.Equal(a[8:14], gwMAC) || !bytes.Equal(a[14:18], gwIP.AsSlice()) {
		t.Fatal("sender is not the gateway")
	}
	if !bytes.Equal(a[18:24], guestMAC) || !bytes.Equal(a[24:28], guestIP.AsSlice()) {
		t.Fatal("target is not the guest")
	}
}

func TestARPOnlyForGateway(t *testing.T) {
	l, _ := newTestL2()
	zero := make(net.HardwareAddr, 6)
	for _, target := range []string{"10.200.0.2", "10.200.0.3", "10.199.0.1", "192.168.1.1", "10.200.0.5"} {
		req := eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, guestIP, zero, netip.MustParseAddr(target)))
		expectDrop(t, l, req, DropARP)
	}
	// Replies and gratuitous ARP from the guest are ignored.
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0806, arpPkt(2, guestMAC, guestIP, gwMAC, gwIP)), DropARP)
	// A request claiming another sender address (spoofing) is ignored.
	other := netip.MustParseAddr("10.200.0.6")
	expectDrop(t, l, eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, other, zero, gwIP)), DropARP)
	// Truncated.
	expectDrop(t, l, eth(bcastMAC, guestMAC, 0x0806, make([]byte, 10)), DropARP)
	// Non-IPv4 protocol type.
	bad := arpPkt(1, guestMAC, guestIP, zero, gwIP)
	binary.BigEndian.PutUint16(bad[2:4], 0x86dd)
	expectDrop(t, l, eth(bcastMAC, guestMAC, 0x0806, bad), DropARP)
}

func TestARPProbeFromUnspecified(t *testing.T) {
	// RFC 5227 probes come from 0.0.0.0 and need no answer for the gateway
	// either, but they must not be treated as an attack: just dropped.
	l, _ := newTestL2()
	zero := make(net.HardwareAddr, 6)
	req := eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, netip.IPv4Unspecified(), zero, guestIP))
	expectDrop(t, l, req, DropARP)
}

func TestIPv4TCPDelivered(t *testing.T) {
	l, _ := newTestL2()
	pkt := ip4pkt(guestIP, netip.MustParseAddr("1.1.1.1"), 6, tcpSyn(40000, 443), ipOpts{})
	// Ethernet pads short frames; the padding must not reach the stack.
	frame := append(eth(gwMAC, guestMAC, 0x0800, pkt), make([]byte, 6)...)
	r := l.Ingress(frame)
	if r.Verdict != Deliver {
		t.Fatalf("verdict = %v (%v), want deliver", r.Verdict, r.Reason)
	}
	if !bytes.Equal(r.Packet, pkt) {
		t.Fatalf("delivered % x, want % x", r.Packet, pkt)
	}
}

func TestIPv4UDPDelivered(t *testing.T) {
	l, _ := newTestL2()
	pkt := ip4pkt(guestIP, svcIP, 17, make([]byte, 8+12), ipOpts{})
	if r := l.Ingress(eth(gwMAC, guestMAC, 0x0800, pkt)); r.Verdict != Deliver {
		t.Fatalf("verdict = %v (%v)", r.Verdict, r.Reason)
	}
}

func TestIPv4Drops(t *testing.T) {
	l, _ := newTestL2()
	pub := netip.MustParseAddr("1.1.1.1")
	cases := []struct {
		name   string
		frame  []byte
		reason DropReason
	}{
		{"not addressed to the gateway", eth(guestMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 6, tcpSyn(1, 2), ipOpts{})), DropNotForGateway},
		{"broadcast mac", eth(bcastMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 17, make([]byte, 8), ipOpts{})), DropNotForGateway},
		{"spoofed source", eth(gwMAC, guestMAC, 0x0800, ip4pkt(netip.MustParseAddr("10.200.0.6"), pub, 6, tcpSyn(1, 2), ipOpts{})), DropSpoofed},
		{"dhcp from 0.0.0.0", eth(gwMAC, guestMAC, 0x0800, ip4pkt(netip.IPv4Unspecified(), netip.MustParseAddr("255.255.255.255"), 17, make([]byte, 8), ipOpts{})), DropSpoofed},
		{"version 6 in an IPv4 frame", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 6, tcpSyn(1, 2), ipOpts{version: 6})), DropMalformed},
		{"short ihl", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 6, tcpSyn(1, 2), ipOpts{ihl: 4})), DropMalformed},
		{"length beyond frame", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 6, tcpSyn(1, 2), ipOpts{totalLen: 1000})), DropMalformed},
		{"truncated header", eth(gwMAC, guestMAC, 0x0800, make([]byte, 12)), DropMalformed},
		{"broadcast", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, netip.MustParseAddr("255.255.255.255"), 17, make([]byte, 8), ipOpts{})), DropBroadcast},
		{"subnet broadcast", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, netip.MustParseAddr("10.200.0.3"), 17, make([]byte, 8), ipOpts{})), DropBroadcast},
		{"multicast", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, netip.MustParseAddr("224.0.0.251"), 17, make([]byte, 8), ipOpts{})), DropBroadcast},
		{"igmp", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 2, make([]byte, 8), ipOpts{})), DropProtocol},
		{"gre", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 47, make([]byte, 8), ipOpts{})), DropProtocol},
		{"sctp", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 132, make([]byte, 8), ipOpts{})), DropProtocol},
		{"ipv6 in ipv4", eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 41, make([]byte, 40), ipOpts{})), DropProtocol},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) { expectDrop(t, l, tc.frame, tc.reason) })
	}
}

func checkEchoReply(t *testing.T, frame []byte, from netip.Addr, id, seq uint16, data []byte) {
	t.Helper()
	if !bytes.Equal(frame[0:6], guestMAC) || !bytes.Equal(frame[6:12], gwMAC) {
		t.Fatalf("bad ethernet header % x", frame[:14])
	}
	ip := frame[14:]
	if checksum(ip[:20], 0) != 0 {
		t.Fatal("bad IPv4 header checksum")
	}
	if !bytes.Equal(ip[12:16], from.AsSlice()) || !bytes.Equal(ip[16:20], guestIP.AsSlice()) {
		t.Fatalf("reply %v -> %v", ip[12:16], ip[16:20])
	}
	if ip[9] != 1 {
		t.Fatal("not ICMP")
	}
	ic := ip[20:]
	if ic[0] != 0 || ic[1] != 0 {
		t.Fatalf("icmp type/code %d/%d, want echo reply", ic[0], ic[1])
	}
	if checksum(ic, 0) != 0 {
		t.Fatal("bad ICMP checksum")
	}
	if binary.BigEndian.Uint16(ic[4:6]) != id || binary.BigEndian.Uint16(ic[6:8]) != seq || !bytes.Equal(ic[8:], data) {
		t.Fatal("echo id/seq/data not preserved")
	}
}

func TestEchoToServiceAddress(t *testing.T) {
	l, _ := newTestL2()
	data := []byte("crew ping payload")
	r := l.Ingress(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(8, 77, 3, data), ipOpts{})))
	if r.Verdict != Reply {
		t.Fatalf("verdict = %v (%v), want reply", r.Verdict, r.Reason)
	}
	checkEchoReply(t, r.Packet, svcIP, 77, 3, data)
}

func TestEchoToGateway(t *testing.T) {
	l, _ := newTestL2()
	r := l.Ingress(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, gwIP, 1, icmpEcho(8, 1, 1, nil), ipOpts{})))
	if r.Verdict != Reply {
		t.Fatalf("verdict = %v (%v), want reply", r.Verdict, r.Reason)
	}
	checkEchoReply(t, r.Packet, gwIP, 1, 1, nil)
}

func TestICMPDrops(t *testing.T) {
	l, _ := newTestL2()
	pub := netip.MustParseAddr("8.8.8.8")
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, pub, 1, icmpEcho(8, 1, 1, nil), ipOpts{})), DropICMP)
	// Echo replies, unreachables and timestamps from the guest go nowhere.
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(0, 1, 1, nil), ipOpts{})), DropICMP)
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(3, 1, 1, nil), ipOpts{})), DropICMP)
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(13, 1, 1, nil), ipOpts{})), DropICMP)
	// Fragmented or truncated echo.
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(8, 1, 1, nil), ipOpts{flagsFrag: 0x2000})), DropICMP)
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, []byte{8, 0, 0}, ipOpts{})), DropICMP)
	// Bad ICMP checksum.
	bad := icmpEcho(8, 1, 1, []byte("x"))
	bad[2] ^= 0xff
	expectDrop(t, l, eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, bad, ipOpts{})), DropICMP)
}

func TestEchoRateLimit(t *testing.T) {
	l, clk := newTestL2()
	ping := func() Verdict {
		return l.Ingress(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(8, 1, 1, nil), ipOpts{}))).Verdict
	}
	for i := 0; i < 10; i++ {
		if v := ping(); v != Reply {
			t.Fatalf("ping %d: %v", i, v)
		}
	}
	if r := l.Ingress(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(8, 1, 1, nil), ipOpts{}))); r.Verdict != Drop || r.Reason != DropRateLimited {
		t.Fatalf("11th ping in the same instant: %v %v", r.Verdict, r.Reason)
	}
	clk.t = clk.t.Add(100 * time.Millisecond)
	if v := ping(); v != Reply {
		t.Fatalf("ping after 100ms: %v", v)
	}
	if v := ping(); v != Drop {
		t.Fatalf("second ping after 100ms: %v", v)
	}
	clk.t = clk.t.Add(10 * time.Second)
	for i := 0; i < 10; i++ {
		if v := ping(); v != Reply {
			t.Fatalf("burst after idle, ping %d: %v", i, v)
		}
	}
	if v := ping(); v != Drop {
		t.Fatal("burst must not exceed 10")
	}
}

func TestEgress(t *testing.T) {
	l, _ := newTestL2()
	pkt := ip4pkt(netip.MustParseAddr("1.1.1.1"), guestIP, 6, tcpSyn(443, 40000), ipOpts{})
	f, ok := l.Egress(nil, pkt)
	if !ok {
		t.Fatal("egress to guest refused")
	}
	if !bytes.Equal(f[0:6], guestMAC) || !bytes.Equal(f[6:12], gwMAC) || binary.BigEndian.Uint16(f[12:14]) != 0x0800 {
		t.Fatalf("bad ethernet header % x", f[:14])
	}
	if !bytes.Equal(f[14:], pkt) {
		t.Fatal("payload changed")
	}
	// Anything not addressed to the guest never leaves.
	other := ip4pkt(netip.MustParseAddr("1.1.1.1"), netip.MustParseAddr("10.200.0.6"), 6, tcpSyn(443, 40000), ipOpts{})
	if _, ok := l.Egress(nil, other); ok {
		t.Fatal("egress to another address allowed")
	}
	if _, ok := l.Egress(nil, []byte{0x60, 0, 0, 0}); ok {
		t.Fatal("non-IPv4 egress allowed")
	}
}
