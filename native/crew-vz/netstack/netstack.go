// Package netstack is the vz driver's isolation boundary (§14.3, §19.4 #7):
// a per-VM userspace network built on gVisor's tcpip stack. The guest's NIC
// is one end of a datagram socketpair (one ethernet frame per datagram);
// this package owns the other end.
//
//   - L2 (frame.go) filters every frame: ARP is answered only for the
//     gateway, IPv6 and anything that isn't TCP, UDP or ICMP echo is
//     dropped, echo to the host is answered here at 10/s.
//   - TCP and UDP go to gVisor in promiscuous mode, whose forwarders hand
//     every new flow to netpolicy.Route: the service address goes to
//     guest.sock or the cache VM, everything else is dialled by this
//     process as the Mac, after blocked4/site4 checks on the socket address
//     actually connected (net.Dialer.Control).
//   - Refusals are RST for TCP and ICMP port unreachable for UDP.
package netstack

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/netpolicy"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// GatewayMAC is the helper's MAC on every VM's link.
var GatewayMAC = config.GatewayMAC

const (
	nicID = 1

	dialTimeout    = 30 * time.Second
	udpIdle        = 60 * time.Second
	udpIdleDNS     = 15 * time.Second
	tcpMaxInFlight = 512
	// Copy buffers start small (idle connections are cheap) and grow once a
	// read fills one (bulk transfers are fast).
	copyBufSmall = 16 << 10
	copyBufLarge = 128 << 10
)

// DialFunc dials a flow's target.
type DialFunc func(ctx context.Context, network, address string) (net.Conn, error)

// Options configures one VM's network.
type Options struct {
	Policy      *netpolicy.Policy
	Limiter     *netpolicy.ConnLimiter
	GuestMAC    net.HardwareAddr
	MTU         int
	GuestSocket string // vms/<id>/guest.sock

	// DialDirect replaces the dialer for Direct flows (tests only). The
	// default checks Policy.CheckDialAddress in net.Dialer.Control.
	DialDirect DialFunc

	Logger *slog.Logger
}

// Stats is a snapshot of the network's counters.
type Stats struct {
	ConnsOpen     int               `json:"conns_open"`
	ConnsRefused  int64             `json:"conns_refused_cap"`
	PolicyRefused int64             `json:"policy_refused"`
	DialFailed    int64             `json:"dial_failed"`
	FramesIn      uint64            `json:"frames_in"`
	FramesOut     uint64            `json:"frames_out"`
	FramesOutLost uint64            `json:"frames_out_lost"`
	Drops         map[string]uint64 `json:"drops,omitempty"`
}

// Netstack is one VM's network.
type Netstack struct {
	opts    Options
	log     *slog.Logger
	l2      *L2
	stack   *stack.Stack
	link    *link
	limiter *netpolicy.ConnLimiter
	policy  *netpolicy.Policy

	dialDirect  DialFunc
	dialService DialFunc

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	policyRefused atomic.Int64
	dialFailed    atomic.Int64
}

// New builds the stack. Call Run with the helper's end of the socketpair.
func New(o Options) (*Netstack, error) {
	if o.Policy == nil || o.Limiter == nil {
		return nil, errors.New("netstack: Policy and Limiter are required")
	}
	if len(o.GuestMAC) != 6 || string(o.GuestMAC) == string(GatewayMAC) {
		return nil, fmt.Errorf("netstack: guest MAC %s unusable", o.GuestMAC)
	}
	if o.MTU == 0 {
		o.MTU = 1500
	}
	if o.Logger == nil {
		o.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	p := o.Policy
	n := &Netstack{
		opts:    o,
		log:     o.Logger,
		limiter: o.Limiter,
		policy:  p,
		l2: NewL2(L2Config{
			GatewayMAC: GatewayMAC,
			GuestMAC:   o.GuestMAC,
			Gateway:    p.Gateway,
			Guest:      p.Guest,
			ServiceIP:  p.ServiceIP,
		}),
	}
	n.ctx, n.cancel = context.WithCancel(context.Background())

	direct := &net.Dialer{
		Timeout:   dialTimeout,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			return p.CheckDialAddress(network, address)
		},
	}
	service := &net.Dialer{
		Timeout:   dialTimeout,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			return p.CheckServiceDialAddress(network, address)
		},
	}
	n.dialDirect = direct.DialContext
	if o.DialDirect != nil {
		n.dialDirect = o.DialDirect
	}
	n.dialService = service.DialContext

	n.link = &link{l2: n.l2, mtu: uint32(o.MTU)}
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	n.stack = s
	if err := tuneTCP(s); err != nil {
		return nil, err
	}
	if err := s.CreateNIC(nicID, n.link); err != nil {
		return nil, fmt.Errorf("netstack: create NIC: %s", err)
	}
	gw := p.Gateway.As4()
	if err := s.AddProtocolAddress(nicID, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: tcpip.AddrFrom4(gw), PrefixLen: 30},
	}, stack.AddressProperties{}); err != nil {
		return nil, fmt.Errorf("netstack: add address: %s", err)
	}
	// Promiscuous: accept packets for any destination (the forwarders see
	// them). Spoofing: reply from any source (the remote's address).
	s.SetPromiscuousMode(nicID, true)
	s.SetSpoofing(nicID, true)
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: nicID}})

	tcpFwd := tcp.NewForwarder(s, 0, tcpMaxInFlight, n.handleTCP)
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)
	udpFwd := udp.NewForwarder(s, n.handleUDP)
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)
	return n, nil
}

func tuneTCP(s *stack.Stack) error {
	opts := []tcpip.SettableTransportProtocolOption{
		ptr(tcpip.TCPSACKEnabled(true)),
		ptr(tcpip.TCPModerateReceiveBufferOption(true)),
		// The guest is microseconds away, so small windows still fill the
		// link (1 MiB at 100us RTT is 80 Gbit/s); they also bound what a
		// guest can pin in this process, which is outside its own memory:
		// max_conns x (receive + send) at most, 2 GiB at 1024 connections.
		&tcpip.TCPReceiveBufferSizeRangeOption{Min: 4 << 10, Default: 128 << 10, Max: 1 << 20},
		&tcpip.TCPSendBufferSizeRangeOption{Min: 4 << 10, Default: 128 << 10, Max: 1 << 20},
		ptr(tcpip.CongestionControlOption("cubic")),
	}
	for _, o := range opts {
		if err := s.SetTransportProtocolOption(tcp.ProtocolNumber, o); err != nil {
			return fmt.Errorf("netstack: tcp option %T: %s", o, err)
		}
	}
	return nil
}

func ptr[T any](v T) *T { return &v }

// Run attaches conn (the helper's end of the socketpair) and moves frames
// from the guest into the stack until conn is closed or Close is called.
func (n *Netstack) Run(conn *net.UnixConn) error {
	n.link.setConn(conn)
	go func() {
		<-n.ctx.Done()
		conn.Close()
	}()
	buf := make([]byte, 65536+ethHeaderLen)
	for {
		k, err := conn.Read(buf)
		if err != nil {
			if n.ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		n.link.framesIn.Add(1)
		r := n.l2.Ingress(buf[:k])
		switch r.Verdict {
		case Deliver:
			n.link.deliver(r.Packet)
		case Reply:
			n.link.writeFrame(r.Packet)
		}
	}
}

// Close tears down the stack and every proxied flow.
func (n *Netstack) Close() {
	n.cancel()
	n.stack.Close()
	n.wg.Wait()
}

// Stats returns the current counters.
func (n *Netstack) Stats() Stats {
	st := Stats{
		ConnsOpen:     n.limiter.Open(),
		ConnsRefused:  n.limiter.Refused(),
		PolicyRefused: n.policyRefused.Load(),
		DialFailed:    n.dialFailed.Load(),
		FramesIn:      n.link.framesIn.Load(),
		FramesOut:     n.link.framesOut.Load(),
		FramesOutLost: n.link.framesLost.Load(),
	}
	for r, c := range n.l2.Drops() {
		if st.Drops == nil {
			st.Drops = map[string]uint64{}
		}
		st.Drops[r.String()] = c
	}
	return st
}

func addrPort(a tcpip.Address, port uint16) netip.AddrPort {
	b := a.As4()
	return netip.AddrPortFrom(netip.AddrFrom4(b), port)
}

func (n *Netstack) dial(ctx context.Context, d netpolicy.Decision, network string) (net.Conn, error) {
	switch d.Action {
	case netpolicy.GuestSocket:
		var dl net.Dialer
		return dl.DialContext(ctx, "unix", n.opts.GuestSocket)
	case netpolicy.Service:
		return n.dialService(ctx, network, d.Target.String())
	case netpolicy.Direct:
		return n.dialDirect(ctx, network, d.Target.String())
	}
	return nil, fmt.Errorf("refused: %s", d.Reason)
}

func (n *Netstack) handleTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	dst := addrPort(id.LocalAddress, id.LocalPort)
	d := n.policy.Route(netpolicy.TCP, dst)
	if d.Action == netpolicy.Refuse {
		n.policyRefused.Add(1)
		n.log.Debug("tcp refused", "dst", dst, "reason", d.Reason)
		r.Complete(true)
		return
	}
	if !n.limiter.Acquire() {
		n.log.Debug("tcp refused: connection cap", "dst", dst)
		r.Complete(true)
		return
	}
	ctx, cancel := context.WithTimeout(n.ctx, dialTimeout)
	remote, err := n.dial(ctx, d, "tcp4")
	cancel()
	if err != nil {
		n.limiter.Release()
		n.dialFailed.Add(1)
		n.log.Debug("tcp dial failed", "dst", dst, "err", err)
		r.Complete(true)
		return
	}
	var wq waiter.Queue
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		n.limiter.Release()
		remote.Close()
		r.Complete(true)
		return
	}
	r.Complete(false)
	ep.SocketOptions().SetKeepAlive(true)
	guest := gonet.NewTCPConn(&wq, ep)
	n.wg.Add(1)
	go func() {
		defer n.wg.Done()
		defer n.limiter.Release()
		n.proxyTCP(guest, remote, ep)
	}()
}

type closeWriter interface{ CloseWrite() error }

// proxyTCP copies both ways with half-close. An error on either side
// aborts both with a reset.
func (n *Netstack) proxyTCP(guest *gonet.TCPConn, remote net.Conn, ep tcpip.Endpoint) {
	stop := context.AfterFunc(n.ctx, func() { abort(guest, remote, ep) })
	defer stop()
	var wg sync.WaitGroup
	var aborted atomic.Bool
	half := func(dst, src net.Conn) {
		defer wg.Done()
		_, err := copyBuf(dst, src)
		if err != nil {
			if aborted.CompareAndSwap(false, true) {
				abort(guest, remote, ep)
			}
			return
		}
		if cw, ok := dst.(closeWriter); ok {
			cw.CloseWrite()
		}
	}
	wg.Add(2)
	go half(remote, guest)
	go half(guest, remote)
	wg.Wait()
	guest.Close()
	remote.Close()
}

func abort(guest *gonet.TCPConn, remote net.Conn, ep tcpip.Endpoint) {
	ep.SocketOptions().SetLinger(tcpip.LingerOption{Enabled: true, Timeout: 0})
	if tc, ok := remote.(*net.TCPConn); ok {
		tc.SetLinger(0)
	}
	guest.Close()
	remote.Close()
}

var (
	smallBufs = sync.Pool{New: func() any { b := make([]byte, copyBufSmall); return &b }}
	largeBufs = sync.Pool{New: func() any { b := make([]byte, copyBufLarge); return &b }}
)

// copyBuf is io.Copy bypassing ReaderFrom/WriterTo, with a buffer that
// grows from copyBufSmall to copyBufLarge the first time a read fills it.
// A clean EOF returns a nil error.
func copyBuf(dst io.Writer, src io.Reader) (int64, error) {
	small := smallBufs.Get().(*[]byte)
	defer smallBufs.Put(small)
	var large *[]byte
	defer func() {
		if large != nil {
			largeBufs.Put(large)
		}
	}()
	buf := *small
	var total int64
	for {
		k, rerr := src.Read(buf)
		if k > 0 {
			w, werr := dst.Write(buf[:k])
			total += int64(w)
			if werr != nil {
				return total, werr
			}
		}
		if rerr != nil {
			return total, eofIsNil(rerr)
		}
		if k == len(buf) && large == nil {
			large = largeBufs.Get().(*[]byte)
			buf = *large
		}
	}
}

func eofIsNil(err error) error {
	if err == io.EOF {
		return nil
	}
	return err
}

func (n *Netstack) handleUDP(r *udp.ForwarderRequest) bool {
	id := r.ID()
	dst := addrPort(id.LocalAddress, id.LocalPort)
	d := n.policy.Route(netpolicy.UDP, dst)
	if d.Action == netpolicy.Refuse {
		n.policyRefused.Add(1)
		n.log.Debug("udp refused", "dst", dst, "reason", d.Reason)
		return false // ICMP port unreachable
	}
	if !n.limiter.Acquire() {
		return false
	}
	// A UDP "dial" is socket+connect: no packets, no waiting.
	ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
	remote, err := n.dial(ctx, d, "udp4")
	cancel()
	if err != nil {
		n.limiter.Release()
		n.dialFailed.Add(1)
		n.log.Debug("udp dial failed", "dst", dst, "err", err)
		return false
	}
	var wq waiter.Queue
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		n.limiter.Release()
		remote.Close()
		return true
	}
	guest := gonet.NewUDPConn(&wq, ep)
	idle := udpIdle
	if dst.Port() == 53 {
		idle = udpIdleDNS
	}
	n.wg.Add(1)
	go func() {
		defer n.wg.Done()
		defer n.limiter.Release()
		n.proxyUDP(guest, remote, idle)
	}()
	return true
}

// proxyUDP relays datagrams both ways until the flow has been idle for
// idle, or either side fails.
func (n *Netstack) proxyUDP(guest *gonet.UDPConn, remote net.Conn, idle time.Duration) {
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	closeBoth := sync.OnceFunc(func() { guest.Close(); remote.Close() })
	stop := context.AfterFunc(n.ctx, closeBoth)
	defer stop()
	// Guest datagrams can't exceed the MTU; replies can be up to 64 KiB.
	relay := func(dst, src net.Conn, size int) {
		buf := make([]byte, size)
		for {
			src.SetReadDeadline(time.Now().Add(idle))
			k, err := src.Read(buf)
			if err != nil {
				var ne net.Error
				if errors.As(err, &ne) && ne.Timeout() &&
					time.Since(time.Unix(0, last.Load())) < idle {
					continue // the other direction is still active
				}
				closeBoth()
				return
			}
			last.Store(time.Now().UnixNano())
			if _, err := dst.Write(buf[:k]); err != nil {
				var oe *net.OpError
				if errors.As(err, &oe) && errors.Is(err, syscall.ECONNREFUSED) {
					continue // ICMP from the far side; UDP carries on
				}
				closeBoth()
				return
			}
		}
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); relay(remote, guest, n.opts.MTU) }()
	go func() { defer wg.Done(); relay(guest, remote, 65536) }()
	wg.Wait()
}

// link is a stack.LinkEndpoint over the socketpair. It carries IPv4 only;
// L2 adds and checks ethernet headers.
type link struct {
	l2  *L2
	mtu uint32

	mu         sync.RWMutex
	dispatcher stack.NetworkDispatcher
	conn       *net.UnixConn

	wmu  sync.Mutex
	wbuf []byte

	framesIn, framesOut, framesLost atomic.Uint64
}

var _ stack.LinkEndpoint = (*link)(nil)

func (l *link) setConn(c *net.UnixConn) {
	l.mu.Lock()
	l.conn = c
	l.mu.Unlock()
}

func (l *link) deliver(ip []byte) {
	l.mu.RLock()
	d := l.dispatcher
	l.mu.RUnlock()
	if d == nil {
		return
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(ip)})
	d.DeliverNetworkPacket(ipv4.ProtocolNumber, pkt)
	pkt.DecRef()
}

// writeFrame sends one frame to the guest. macOS returns ENOBUFS, rather
// than blocking, when the receiving end of a datagram socket is full, so
// back off briefly and retry before giving up on the frame.
func (l *link) writeFrame(f []byte) bool {
	l.mu.RLock()
	c := l.conn
	l.mu.RUnlock()
	if c == nil {
		return false
	}
	delay := 20 * time.Microsecond
	for attempt := 0; ; attempt++ {
		_, err := c.Write(f)
		if err == nil {
			l.framesOut.Add(1)
			return true
		}
		if !errors.Is(err, syscall.ENOBUFS) || attempt >= 12 {
			l.framesLost.Add(1)
			return false
		}
		time.Sleep(delay)
		if delay < 2*time.Millisecond {
			delay *= 2
		}
	}
}

func (l *link) WritePackets(pkts stack.PacketBufferList) (int, tcpip.Error) {
	l.wmu.Lock()
	defer l.wmu.Unlock()
	n := 0
	for _, pkt := range pkts.AsSlice() {
		buf := append(l.wbuf[:0], make([]byte, ethHeaderLen)...)
		for _, s := range pkt.AsSlices() {
			buf = append(buf, s...)
		}
		l.wbuf = buf
		if !l.l2.frameInPlace(buf) {
			l.framesLost.Add(1)
			continue
		}
		if !l.writeFrame(buf) {
			break
		}
		n++
	}
	if n == 0 && pkts.Len() > 0 {
		return 0, &tcpip.ErrWouldBlock{}
	}
	return n, nil
}

func (l *link) MTU() uint32                                  { return l.mtu }
func (l *link) SetMTU(mtu uint32)                            { l.mtu = mtu }
func (l *link) MaxHeaderLength() uint16                      { return 0 }
func (l *link) LinkAddress() tcpip.LinkAddress               { return "" }
func (l *link) SetLinkAddress(tcpip.LinkAddress)             {}
func (l *link) Capabilities() stack.LinkEndpointCapabilities { return 0 }
func (l *link) Attach(d stack.NetworkDispatcher) {
	l.mu.Lock()
	l.dispatcher = d
	l.mu.Unlock()
}
func (l *link) IsAttached() bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.dispatcher != nil
}
func (l *link) Wait()                                   {}
func (l *link) ARPHardwareType() header.ARPHardwareType { return header.ARPHardwareNone }
func (l *link) AddHeader(*stack.PacketBuffer)           {}
func (l *link) ParseHeader(*stack.PacketBuffer) bool    { return true }
func (l *link) Close()                                  {}
func (l *link) SetOnCloseAction(func())                 {}
