// Package netpolicy decides where a guest's connection may go. It does no
// networking itself, so every rule is unit-testable; netstack calls it for
// each new flow, and again from the dialer's Control hook on the socket
// address actually being connected.
package netpolicy

import (
	"fmt"
	"net/netip"
	"sync"
	"sync/atomic"
)

// Proto is an IP protocol number.
type Proto uint8

const (
	TCP Proto = 6
	UDP Proto = 17
)

func (p Proto) String() string {
	switch p {
	case TCP:
		return "tcp"
	case UDP:
		return "udp"
	}
	return fmt.Sprintf("proto(%d)", uint8(p))
}

// Action is what to do with a new flow.
type Action int

const (
	// Refuse: RST for TCP, ICMP port unreachable for UDP.
	Refuse Action = iota
	// Direct: the helper dials Target itself, as the Mac.
	Direct
	// GuestSocket: forward the bytes to the VM's guest.sock.
	GuestSocket
	// Service: dial Target, which is the cache VM or the DNS fallback.
	Service
)

func (a Action) String() string {
	switch a {
	case Refuse:
		return "refuse"
	case Direct:
		return "direct"
	case GuestSocket:
		return "guest_socket"
	case Service:
		return "service"
	}
	return fmt.Sprintf("action(%d)", int(a))
}

// Decision is the result of routing one flow.
type Decision struct {
	Action Action
	Target netip.AddrPort // for Direct and Service
	Reason string         // for Refuse
}

// Blocked4 is the blocked4 set of §14.2: LAN, tailnet, link-local and
// metadata, loopback, documentation and benchmarking ranges, multicast and
// reserved space. It also covers the VM ranges (10.200.0.0/16) and the
// service address, which is reached only through Route.
var Blocked4 = mustPrefixes(
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
	"169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
	"192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
	"198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4",
	"240.0.0.0/4", "255.255.255.255/32",
)

func mustPrefixes(ss ...string) []netip.Prefix {
	out := make([]netip.Prefix, len(ss))
	for i, s := range ss {
		out[i] = netip.MustParsePrefix(s)
	}
	return out
}

// Service ports on the service address.
const (
	PortDNS      = 53
	PortHTTP     = 80
	PortHTTPS    = 443
	PortGuestAPI = 7777
)

// Policy is one VM's view of the network.
type Policy struct {
	Gateway   netip.Addr
	Guest     netip.Addr
	ServiceIP netip.Addr
	// CacheAddr is the cache VM (hostvm/cachevm.ip). Invalid when there is
	// none, in which case 80 and 443 are refused.
	CacheAddr netip.Addr
	// DNSFallback is used for port 53 only when CacheAddr is unset.
	DNSFallback netip.AddrPort
	// Site4 is this site's own addresses (pushed by the agent).
	Site4 []netip.Prefix
}

// CheckDial says whether the helper may connect to a, as the Mac, on the
// guest's behalf. Only IPv4 outside blocked4 and site4 is allowed.
func (p *Policy) CheckDial(a netip.Addr) error {
	if !a.Is4() {
		return fmt.Errorf("%s: only IPv4 is dialled", a)
	}
	for _, pfx := range Blocked4 {
		if pfx.Contains(a) {
			return fmt.Errorf("%s: in blocked4 (%s)", a, pfx)
		}
	}
	for _, pfx := range p.Site4 {
		if pfx.Contains(a) {
			return fmt.Errorf("%s: in site4 (%s)", a, pfx)
		}
	}
	return nil
}

// CheckDialAddress is CheckDial for net.Dialer.Control: network and
// address are exactly what the socket is about to connect to.
func (p *Policy) CheckDialAddress(network, address string) error {
	ap, err := parseDialAddress(network, address)
	if err != nil {
		return err
	}
	return p.CheckDial(ap.Addr())
}

// CheckServiceDialAddress allows only the service targets: the cache VM on
// 53, 80 and 443, and the DNS fallback. It is the Control hook for service
// dials, which are exempt from blocked4 (the cache VM is on a private
// address).
func (p *Policy) CheckServiceDialAddress(network, address string) error {
	ap, err := parseDialAddress(network, address)
	if err != nil {
		return err
	}
	if p.CacheAddr.IsValid() && ap.Addr() == p.CacheAddr {
		switch ap.Port() {
		case PortDNS, PortHTTP, PortHTTPS:
			return nil
		}
	}
	if p.DNSFallback.IsValid() && ap == p.DNSFallback {
		return nil
	}
	return fmt.Errorf("%s: not a service target", ap)
}

func parseDialAddress(network, address string) (netip.AddrPort, error) {
	switch network {
	case "tcp", "tcp4", "udp", "udp4":
	default:
		return netip.AddrPort{}, fmt.Errorf("network %q: only tcp4 and udp4 are dialled", network)
	}
	ap, err := netip.ParseAddrPort(address)
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("dial address %q: %w", address, err)
	}
	if !ap.Addr().Is4() {
		// Includes IPv4-mapped IPv6: the helper only opens IPv4 sockets.
		return netip.AddrPort{}, fmt.Errorf("dial address %s: not IPv4", ap)
	}
	return ap, nil
}

// Route decides what to do with a new flow from the guest to dst.
func (p *Policy) Route(proto Proto, dst netip.AddrPort) Decision {
	a := dst.Addr()
	if !a.Is4() {
		return refuse("not IPv4")
	}
	if dst.Port() == 0 {
		return refuse("port 0")
	}
	if a == p.ServiceIP {
		return p.routeService(proto, dst.Port())
	}
	if err := p.CheckDial(a); err != nil {
		return refuse(err.Error())
	}
	return Decision{Action: Direct, Target: dst}
}

func (p *Policy) routeService(proto Proto, port uint16) Decision {
	switch {
	case proto == TCP && port == PortGuestAPI:
		return Decision{Action: GuestSocket}
	case port == PortDNS && (proto == TCP || proto == UDP):
		if p.CacheAddr.IsValid() {
			return Decision{Action: Service, Target: netip.AddrPortFrom(p.CacheAddr, PortDNS)}
		}
		if p.DNSFallback.IsValid() {
			return Decision{Action: Service, Target: p.DNSFallback}
		}
		return refuse("no cache VM or dns_fallback for DNS")
	case proto == TCP && (port == PortHTTP || port == PortHTTPS):
		if p.CacheAddr.IsValid() {
			return Decision{Action: Service, Target: netip.AddrPortFrom(p.CacheAddr, port)}
		}
		return refuse("no cache VM")
	}
	return refuse(fmt.Sprintf("service address: %v port %d not served", proto, port))
}

func refuse(reason string) Decision { return Decision{Action: Refuse, Reason: reason} }

// ConnLimiter caps the flows (TCP connections and UDP flows) one VM has
// open at once: §14.2's 2048 tracked connections.
type ConnLimiter struct {
	mu      sync.Mutex
	max     int
	open    int
	refused atomic.Int64
}

func NewConnLimiter(max int) *ConnLimiter { return &ConnLimiter{max: max} }

// Acquire takes a slot, or returns false if the VM is at its cap.
func (l *ConnLimiter) Acquire() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.open >= l.max {
		l.refused.Add(1)
		return false
	}
	l.open++
	return true
}

// Release gives back a slot taken by Acquire.
func (l *ConnLimiter) Release() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.open > 0 {
		l.open--
	}
}

// Open is the number of slots in use.
func (l *ConnLimiter) Open() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.open
}

// Refused counts Acquire calls turned away by the cap.
func (l *ConnLimiter) Refused() int64 { return l.refused.Load() }
