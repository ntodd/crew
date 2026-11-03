package netpolicy

import (
	"net/netip"
	"sync"
	"testing"
)

func testPolicy() *Policy {
	return &Policy{
		Gateway:   netip.MustParseAddr("10.200.0.1"),
		Guest:     netip.MustParseAddr("10.200.0.2"),
		ServiceIP: netip.MustParseAddr("10.199.0.1"),
		CacheAddr: netip.MustParseAddr("192.168.64.5"),
		Site4:     []netip.Prefix{netip.MustParsePrefix("203.0.113.7/32"), netip.MustParsePrefix("81.2.69.0/24")},
	}
}

func ap(s string) netip.AddrPort { return netip.MustParseAddrPort(s) }

func TestBlocked4MatchesSpec(t *testing.T) {
	// §14.2's nftables set, verbatim.
	want := []string{"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
		"169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
		"192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
		"224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32"}
	if len(Blocked4) != len(want) {
		t.Fatalf("Blocked4 has %d entries, want %d", len(Blocked4), len(want))
	}
	for i, w := range want {
		if Blocked4[i].String() != w {
			t.Errorf("Blocked4[%d] = %s, want %s", i, Blocked4[i], w)
		}
	}
}

func TestCheckDial(t *testing.T) {
	p := testPolicy()
	cases := []struct {
		addr string
		ok   bool
	}{
		{"1.1.1.1", true},
		{"140.82.112.3", true},
		{"10.0.0.1", false},
		{"10.199.0.1", false}, // the service address itself is never dialled directly
		{"10.200.0.1", false}, // the gateway
		{"10.200.0.6", false}, // another VM's lease
		{"192.168.1.1", false},
		{"169.254.169.254", false},
		{"127.0.0.1", false},
		{"100.100.100.100", false}, // tailnet
		{"172.20.0.1", false},
		{"0.0.0.0", false},
		{"224.0.0.251", false},
		{"255.255.255.255", false},
		{"198.18.0.1", false},
		{"203.0.113.7", false}, // site4 (and TEST-NET-3)
		{"81.2.69.160", false}, // site4 only
		{"81.2.70.1", true},
		{"::1", false},
		{"2606:4700::1111", false},
		{"::ffff:10.0.0.1", false}, // IPv4-mapped IPv6 is refused outright:
		{"::ffff:1.1.1.1", false},  // only IPv4 sockets are ever dialled
	}
	for _, tc := range cases {
		err := p.CheckDial(netip.MustParseAddr(tc.addr))
		if (err == nil) != tc.ok {
			t.Errorf("CheckDial(%s) = %v, want ok=%v", tc.addr, err, tc.ok)
		}
	}
}

func TestCheckDialAddress(t *testing.T) {
	// The form net.Dialer's Control hook sees.
	p := testPolicy()
	if err := p.CheckDialAddress("tcp4", "1.1.1.1:443"); err != nil {
		t.Errorf("public dial refused: %v", err)
	}
	for _, bad := range []struct{ network, addr string }{
		{"tcp4", "10.0.0.1:80"},
		{"udp4", "192.168.1.1:53"},
		{"tcp6", "[2606:4700::1111]:443"},
		{"tcp", "[::ffff:169.254.169.254]:80"},
		{"tcp4", "not-an-address"},
		{"unix", "/tmp/x.sock"},
	} {
		if err := p.CheckDialAddress(bad.network, bad.addr); err == nil {
			t.Errorf("CheckDialAddress(%s, %s) allowed", bad.network, bad.addr)
		}
	}
}

func TestRoute(t *testing.T) {
	p := testPolicy()
	cases := []struct {
		name   string
		proto  Proto
		dst    string
		action Action
		target string
	}{
		{"guest api", TCP, "10.199.0.1:7777", GuestSocket, ""},
		{"guest api over udp", UDP, "10.199.0.1:7777", Refuse, ""},
		{"dns udp", UDP, "10.199.0.1:53", Service, "192.168.64.5:53"},
		{"dns tcp", TCP, "10.199.0.1:53", Service, "192.168.64.5:53"},
		{"cache http", TCP, "10.199.0.1:80", Service, "192.168.64.5:80"},
		{"cache https", TCP, "10.199.0.1:443", Service, "192.168.64.5:443"},
		{"cache https over udp", UDP, "10.199.0.1:443", Refuse, ""},
		{"other service port", TCP, "10.199.0.1:22", Refuse, ""},
		{"other service port udp", UDP, "10.199.0.1:123", Refuse, ""},
		{"public tcp", TCP, "1.1.1.1:443", Direct, "1.1.1.1:443"},
		{"public udp", UDP, "8.8.8.8:53", Direct, "8.8.8.8:53"},
		{"lan", TCP, "192.168.1.1:80", Refuse, ""},
		{"metadata", TCP, "169.254.169.254:80", Refuse, ""},
		{"gateway", TCP, "10.200.0.1:22", Refuse, ""},
		{"cache vm directly", TCP, "192.168.64.5:443", Refuse, ""},
		{"site", TCP, "81.2.69.1:443", Refuse, ""},
		{"port zero", TCP, "1.1.1.1:0", Refuse, ""},
		{"ipv6", TCP, "[2606:4700::1111]:443", Refuse, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := p.Route(tc.proto, ap(tc.dst))
			if d.Action != tc.action {
				t.Fatalf("Route(%v, %s) = %v (%s), want %v", tc.proto, tc.dst, d.Action, d.Reason, tc.action)
			}
			if tc.target != "" && d.Target != ap(tc.target) {
				t.Fatalf("target = %v, want %s", d.Target, tc.target)
			}
			if d.Action == Refuse && d.Reason == "" {
				t.Fatal("refusals must carry a reason")
			}
		})
	}
}

func TestRouteWithoutCache(t *testing.T) {
	p := testPolicy()
	p.CacheAddr = netip.Addr{}
	if d := p.Route(TCP, ap("10.199.0.1:443")); d.Action != Refuse {
		t.Errorf("443 with no cache: %v", d.Action)
	}
	if d := p.Route(UDP, ap("10.199.0.1:53")); d.Action != Refuse {
		t.Errorf("dns with no cache and no fallback: %v", d.Action)
	}
	p.DNSFallback = ap("1.1.1.1:53")
	for _, proto := range []Proto{UDP, TCP} {
		d := p.Route(proto, ap("10.199.0.1:53"))
		if d.Action != Service || d.Target != ap("1.1.1.1:53") {
			t.Errorf("dns fallback over %v: %+v", proto, d)
		}
	}
	if d := p.Route(TCP, ap("10.199.0.1:80")); d.Action != Refuse {
		t.Errorf("80 must not use the dns fallback: %v", d.Action)
	}
}

func TestCacheWinsOverFallback(t *testing.T) {
	p := testPolicy()
	p.DNSFallback = ap("1.1.1.1:53")
	if d := p.Route(UDP, ap("10.199.0.1:53")); d.Target != ap("192.168.64.5:53") {
		t.Errorf("dns went to %v, want the cache VM", d.Target)
	}
}

func TestCheckServiceDial(t *testing.T) {
	p := testPolicy()
	p.DNSFallback = ap("9.9.9.9:53")
	for _, ok := range []string{"192.168.64.5:53", "192.168.64.5:80", "192.168.64.5:443", "9.9.9.9:53"} {
		if err := p.CheckServiceDialAddress("tcp4", ok); err != nil {
			t.Errorf("service dial %s refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"192.168.64.5:22", "192.168.64.6:443", "9.9.9.9:443", "1.1.1.1:53"} {
		if err := p.CheckServiceDialAddress("tcp4", bad); err == nil {
			t.Errorf("service dial %s allowed", bad)
		}
	}
}

func TestConnLimiter(t *testing.T) {
	l := NewConnLimiter(3)
	for i := 0; i < 3; i++ {
		if !l.Acquire() {
			t.Fatalf("acquire %d refused", i)
		}
	}
	if l.Acquire() {
		t.Fatal("4th acquire allowed with max 3")
	}
	if l.Open() != 3 {
		t.Fatalf("open = %d", l.Open())
	}
	l.Release()
	if !l.Acquire() {
		t.Fatal("acquire after release refused")
	}
	if l.Refused() != 1 {
		t.Fatalf("refused = %d", l.Refused())
	}
}

func TestConnLimiterConcurrent(t *testing.T) {
	l := NewConnLimiter(2048)
	var wg sync.WaitGroup
	var mu sync.Mutex
	granted := 0
	for i := 0; i < 4096; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Acquire() {
				mu.Lock()
				granted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if granted != 2048 || l.Open() != 2048 {
		t.Fatalf("granted %d, open %d; want 2048", granted, l.Open())
	}
}
