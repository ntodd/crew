package netstack

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vz/netpolicy"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/link/ethernet"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// These tests put a second gVisor stack, with real ethernet and ARP, on the
// guest's end of a datagram socketpair: the same wire the VZ NIC uses.

func socketpair(t testing.TB) (helper, guest *net.UnixConn) {
	t.Helper()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	conns := make([]*net.UnixConn, 2)
	for i, fd := range fds {
		if err := TuneSocket(fd, 1500); err != nil {
			t.Fatal(err)
		}
		f := os.NewFile(uintptr(fd), fmt.Sprintf("pair%d", i))
		c, err := net.FileConn(f)
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = c.(*net.UnixConn)
	}
	t.Cleanup(func() { conns[0].Close(); conns[1].Close() })
	return conns[0], conns[1]
}

type fakeGuest struct {
	s      *stack.Stack
	ch     *channel.Endpoint
	cancel context.CancelFunc
}

func startGuest(t testing.TB, conn *net.UnixConn) *fakeGuest {
	t.Helper()
	ch := channel.New(4096, 1500, tcpip.LinkAddress(guestMAC))
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, arp.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	if err := s.CreateNIC(1, ethernet.New(ch)); err != nil {
		t.Fatal(err)
	}
	if err := s.AddProtocolAddress(1, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: tcpip.AddrFrom4(guestIP.As4()), PrefixLen: 30},
	}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	subnet, _ := tcpip.NewSubnet(tcpip.AddrFrom4([4]byte{10, 200, 0, 0}), tcpip.MaskFromBytes([]byte{255, 255, 255, 252}))
	s.SetRouteTable([]tcpip.Route{
		{Destination: subnet, NIC: 1},
		{Destination: header.IPv4EmptySubnet, Gateway: tcpip.AddrFrom4(gwIP.As4()), NIC: 1},
	})
	ctx, cancel := context.WithCancel(context.Background())
	g := &fakeGuest{s: s, ch: ch, cancel: cancel}
	go func() {
		for {
			pkt := ch.ReadContext(ctx)
			if pkt == nil {
				return
			}
			v := pkt.ToView()
			for {
				_, err := conn.Write(v.AsSlice())
				if !errors.Is(err, syscall.ENOBUFS) {
					break
				}
				time.Sleep(50 * time.Microsecond)
			}
			v.Release()
			pkt.DecRef()
		}
	}()
	go func() {
		buf := make([]byte, 65536)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(buf[:n])})
			ch.InjectInbound(0, pkt)
			pkt.DecRef()
		}
	}()
	t.Cleanup(func() { cancel(); s.Close() })
	return g
}

func (g *fakeGuest) dialTCP(ctx context.Context, dst string) (*gonet.TCPConn, error) {
	ap := netip.MustParseAddrPort(dst)
	return gonet.DialContextTCP(ctx, g.s, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4(ap.Addr().As4()), Port: ap.Port()}, ipv4.ProtocolNumber)
}

func (g *fakeGuest) dialUDP(dst string) (*gonet.UDPConn, error) {
	ap := netip.MustParseAddrPort(dst)
	return gonet.DialUDP(g.s, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFrom4(ap.Addr().As4()), Port: ap.Port()}, ipv4.ProtocolNumber)
}

type harness struct {
	ns        *Netstack
	guest     *fakeGuest
	guestSock string
	policy    *netpolicy.Policy
	limiter   *netpolicy.ConnLimiter
}

type harnessOpts struct {
	maxConns   int
	dialDirect DialFunc
	dnsUp      netip.AddrPort
}

func newHarness(t testing.TB, o harnessOpts) *harness {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "cvzns")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if o.maxConns == 0 {
		o.maxConns = 2048
	}
	p := &netpolicy.Policy{Gateway: gwIP, Guest: guestIP, ServiceIP: svcIP, DNSFallback: o.dnsUp}
	lim := netpolicy.NewConnLimiter(o.maxConns)
	h := &harness{guestSock: filepath.Join(dir, "guest.sock"), policy: p, limiter: lim}
	ns, err := New(Options{
		Policy: p, Limiter: lim, GuestMAC: guestMAC, MTU: 1500,
		GuestSocket: h.guestSock, DialDirect: o.dialDirect,
	})
	if err != nil {
		t.Fatal(err)
	}
	helperEnd, guestEnd := socketpair(t)
	go ns.Run(helperEnd)
	t.Cleanup(ns.Close)
	h.ns = ns
	h.guest = startGuest(t, guestEnd)
	return h
}

// serveGuestSocket accepts on guest.sock and hands each conn to fn.
func (h *harness) serveGuestSocket(t testing.TB, fn func(net.Conn)) {
	t.Helper()
	ln, err := net.Listen("unix", h.guestSock)
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
			go fn(c)
		}
	}()
}

func ctxT(t testing.TB, d time.Duration) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	t.Cleanup(cancel)
	return ctx
}

func TestGuestAPIGoesToGuestSocket(t *testing.T) {
	h := newHarness(t, harnessOpts{})
	got := make(chan string, 1)
	h.serveGuestSocket(t, func(c net.Conn) {
		defer c.Close()
		b, _ := io.ReadAll(c) // until the guest half-closes
		got <- string(b)
		c.Write([]byte("pong"))
	})
	c, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "10.199.0.1:7777")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.Write([]byte("ping from guest"))
	c.CloseWrite()
	select {
	case s := <-got:
		if s != "ping from guest" {
			t.Fatalf("guest.sock got %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("nothing arrived on guest.sock")
	}
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	reply, err := io.ReadAll(c)
	if err != nil || string(reply) != "pong" {
		t.Fatalf("reply %q, %v", reply, err)
	}
}

func TestGuestSocketMissingIsRefused(t *testing.T) {
	h := newHarness(t, harnessOpts{})
	_, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "10.199.0.1:7777")
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("dial with no guest.sock: %v", err)
	}
}

func TestBlockedDestinationsAreRefused(t *testing.T) {
	dialed := make(chan string, 10)
	h := newHarness(t, harnessOpts{dialDirect: func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed <- address
		return nil, errors.New("test dialer: should not be reached")
	}})
	h.policy.Site4 = []netip.Prefix{netip.MustParsePrefix("81.2.69.0/24")}
	for _, dst := range []string{
		"10.0.0.1:80", "192.168.1.1:80", "169.254.169.254:80", "10.200.0.1:22",
		// (127/8 isn't here: the guest's own stack never routes it to eth0.)
		"10.200.0.6:22", "100.100.100.100:443", "172.17.0.1:2375",
		"10.199.0.1:22", "10.199.0.1:443", // no cache VM configured
		"81.2.69.10:443", // site4
	} {
		start := time.Now()
		_, err := h.guest.dialTCP(ctxT(t, 5*time.Second), dst)
		if err == nil || !strings.Contains(err.Error(), "refused") {
			t.Errorf("%s: %v, want connection refused", dst, err)
		}
		if time.Since(start) > 2*time.Second {
			t.Errorf("%s: refusal took %v", dst, time.Since(start))
		}
	}
	select {
	case a := <-dialed:
		t.Fatalf("blocked destination %s reached the dialer", a)
	default:
	}
}

func TestDirectDialPassesTarget(t *testing.T) {
	echo, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	var mu sync.Mutex
	var targets []string
	h := newHarness(t, harnessOpts{dialDirect: func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		targets = append(targets, network+" "+address)
		mu.Unlock()
		var d net.Dialer
		return d.DialContext(ctx, "tcp4", echo.Addr().String())
	}})
	c, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "140.82.112.3:443")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	msg := bytes.Repeat([]byte("crew"), 50_000)
	go func() { c.Write(msg); c.CloseWrite() }()
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	back, err := io.ReadAll(c)
	if err != nil || !bytes.Equal(back, msg) {
		t.Fatalf("echo returned %d bytes (%v), want %d", len(back), err, len(msg))
	}
	mu.Lock()
	defer mu.Unlock()
	if len(targets) != 1 || targets[0] != "tcp4 140.82.112.3:443" {
		t.Fatalf("dialled %v", targets)
	}
}

func TestRealDialersCheckTheDialledAddress(t *testing.T) {
	// The default dialers re-check policy in net.Dialer.Control on the
	// socket address actually connected, independent of Route.
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	h := newHarness(t, harnessOpts{})
	_, err = h.ns.dialDirect(context.Background(), "tcp4", ln.Addr().String())
	if err == nil || !strings.Contains(err.Error(), "blocked4") {
		t.Fatalf("direct dial to loopback: %v", err)
	}
	_, err = h.ns.dialService(context.Background(), "tcp4", ln.Addr().String())
	if err == nil || !strings.Contains(err.Error(), "not a service target") {
		t.Fatalf("service dial to an arbitrary address: %v", err)
	}
}

func udpPkt(srcPort, dstPort uint16, payload []byte) []byte {
	p := make([]byte, 8+len(payload))
	p[0], p[1] = byte(srcPort>>8), byte(srcPort)
	p[2], p[3] = byte(dstPort>>8), byte(dstPort)
	p[4], p[5] = byte(len(p)>>8), byte(len(p))
	copy(p[8:], payload) // checksum 0: none, which IPv4 allows
	return p
}

func TestUDPRefusalIsPortUnreachable(t *testing.T) {
	// gonet's UDPConn doesn't surface ICMP errors, so check the wire: the
	// guest must get ICMP port unreachable from the refused destination.
	_, g := rawLink(t)
	for _, dst := range []string{"192.168.1.1", "10.199.0.1"} {
		d := netip.MustParseAddr(dst)
		port := uint16(53)
		if dst == "10.199.0.1" {
			port = 123 // not a service port
		}
		g.Write(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, d, 17, udpPkt(40000, port, []byte("q")), ipOpts{})))
		f, err := readFrame(g, 2*time.Second)
		if err != nil {
			t.Fatalf("%s: no reply: %v", dst, err)
		}
		ip := f[14:]
		ihl := int(ip[0]&0xf) * 4
		if ip[9] != 1 || ip[ihl] != 3 || ip[ihl+1] != 3 {
			t.Fatalf("%s: reply proto %d type %d code %d, want ICMP 3/3", dst, ip[9], ip[ihl], ip[ihl+1])
		}
		if netip.AddrFrom4([4]byte(ip[12:16])) != d || netip.AddrFrom4([4]byte(ip[16:20])) != guestIP {
			t.Fatalf("%s: unreachable %v -> %v", dst, ip[12:16], ip[16:20])
		}
	}
}

func TestDNSGoesToFallback(t *testing.T) {
	up, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, addr, err := up.ReadFrom(buf)
			if err != nil {
				return
			}
			up.WriteTo(append([]byte("answer:"), buf[:n]...), addr)
		}
	}()
	h := newHarness(t, harnessOpts{dnsUp: netip.MustParseAddrPort(up.LocalAddr().String())})
	c, err := h.guest.dialUDP("10.199.0.1:53")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for i := 0; i < 3; i++ {
		q := fmt.Sprintf("q%d", i)
		c.Write([]byte(q))
		c.SetReadDeadline(time.Now().Add(3 * time.Second))
		buf := make([]byte, 100)
		n, err := c.Read(buf)
		if err != nil || string(buf[:n]) != "answer:"+q {
			t.Fatalf("dns reply %q, %v", buf[:n], err)
		}
	}
	if h.limiter.Open() != 1 {
		t.Fatalf("one UDP flow should hold one slot, open = %d", h.limiter.Open())
	}
}

func TestConnectionCap(t *testing.T) {
	h := newHarness(t, harnessOpts{maxConns: 2})
	release := make(chan struct{})
	h.serveGuestSocket(t, func(c net.Conn) {
		<-release
		c.Close()
	})
	var held []*gonet.TCPConn
	for i := 0; i < 2; i++ {
		c, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "10.199.0.1:7777")
		if err != nil {
			t.Fatalf("conn %d: %v", i, err)
		}
		held = append(held, c)
	}
	if _, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "10.199.0.1:7777"); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("conn over the cap: %v", err)
	}
	if _, err := h.guest.dialUDP("10.199.0.1:53"); err != nil {
		t.Fatal(err) // UDP dial is local; the refusal shows on read
	}
	close(release)
	for _, c := range held {
		c.Close()
	}
	deadline := time.Now().Add(5 * time.Second)
	for h.limiter.Open() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.limiter.Open() != 0 {
		t.Fatalf("slots not released: %d open", h.limiter.Open())
	}
	release2 := make(chan struct{})
	defer close(release2)
	c, err := h.guest.dialTCP(ctxT(t, 5*time.Second), "10.199.0.1:7777")
	if err != nil {
		t.Fatalf("after release: %v", err)
	}
	c.Close()
	if h.limiter.Refused() < 1 {
		t.Fatal("cap refusal not counted")
	}
}

// rawLink is a guest end with no stack, for writing hand-made frames.
func rawLink(t *testing.T) (*harness, *net.UnixConn) {
	t.Helper()
	p := &netpolicy.Policy{Gateway: gwIP, Guest: guestIP, ServiceIP: svcIP}
	ns, err := New(Options{Policy: p, Limiter: netpolicy.NewConnLimiter(10), GuestMAC: guestMAC})
	if err != nil {
		t.Fatal(err)
	}
	helperEnd, guestEnd := socketpair(t)
	go ns.Run(helperEnd)
	t.Cleanup(ns.Close)
	return &harness{ns: ns}, guestEnd
}

func readFrame(c *net.UnixConn, d time.Duration) ([]byte, error) {
	c.SetReadDeadline(time.Now().Add(d))
	buf := make([]byte, 2048)
	n, err := c.Read(buf)
	return buf[:n], err
}

func TestRawFramesOverTheWire(t *testing.T) {
	h, g := rawLink(t)
	zero := make(net.HardwareAddr, 6)

	// ARP for anything but the gateway: silence.
	g.Write(eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, guestIP, zero, netip.MustParseAddr("10.200.0.3"))))
	if f, err := readFrame(g, 200*time.Millisecond); err == nil {
		t.Fatalf("unexpected reply % x", f)
	}
	// ARP for the gateway: answered.
	g.Write(eth(bcastMAC, guestMAC, 0x0806, arpPkt(1, guestMAC, guestIP, zero, gwIP)))
	f, err := readFrame(g, 2*time.Second)
	if err != nil || binary16(f[12:14]) != 0x0806 || binary16(f[14+6:14+8]) != 2 {
		t.Fatalf("no ARP reply: % x %v", f, err)
	}
	// IPv6 (here a router solicitation): dropped and counted.
	g.Write(eth(gwMAC, guestMAC, 0x86dd, make([]byte, 48)))
	// Echo to the service address: answered.
	g.Write(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, svcIP, 1, icmpEcho(8, 9, 1, []byte("hi")), ipOpts{})))
	f, err = readFrame(g, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	checkEchoReply(t, f, svcIP, 9, 1, []byte("hi"))
	// Echo to the internet: silence.
	g.Write(eth(gwMAC, guestMAC, 0x0800, ip4pkt(guestIP, netip.MustParseAddr("1.1.1.1"), 1, icmpEcho(8, 9, 2, nil), ipOpts{})))
	if f, err := readFrame(g, 200*time.Millisecond); err == nil {
		t.Fatalf("unexpected reply % x", f)
	}
	st := h.ns.Stats()
	if st.Drops["ipv6"] != 1 || st.Drops["arp"] != 1 || st.Drops["icmp"] != 1 {
		t.Fatalf("drops = %v", st.Drops)
	}
}

func binary16(b []byte) uint16 { return uint16(b[0])<<8 | uint16(b[1]) }

// BenchmarkDownloadViaGuestSocket measures guest-side TCP download
// throughput through the netstack (both ends userspace gVisor, so this is
// a floor for the helper's share of the cost, not a VM number).
func BenchmarkDownloadViaGuestSocket(b *testing.B) {
	h := newHarness(b, harnessOpts{})
	const size = 256 << 20
	chunk := bytes.Repeat([]byte{0xa5}, 256<<10)
	h.serveGuestSocket(b, func(c net.Conn) {
		defer c.Close()
		for sent := 0; sent < size; sent += len(chunk) {
			if _, err := c.Write(chunk); err != nil {
				return
			}
		}
	})
	b.SetBytes(size)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c, err := h.guest.dialTCP(ctxT(b, 30*time.Second), "10.199.0.1:7777")
		if err != nil {
			b.Fatal(err)
		}
		n, err := io.Copy(io.Discard, c)
		c.Close()
		if err != nil || n != size {
			b.Fatalf("got %d bytes, %v", n, err)
		}
	}
}
