package vmctl

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// testBox is a fake host whose packet filter is loaded and healthy: the
// shipped ruleset, the connection cap, and site4 as crew-net fills it
// (the uplink's 192.168.64.0/24 and the egress address).
type testBox struct {
	*fakeSys
	table string
	site4 []string // what `nft -j list set inet crew site4` shows
}

func newBox(t *testing.T) *testBox {
	t.Helper()
	b := &testBox{fakeSys: newFake(),
		table: string(mustRead(t, "../ruleset/testdata/nft-1.1.6-busy.json")),
		site4: []string{"192.168.64.0/24", "198.51.100.20/32"}}
	mangle := string(mustRead(t, "../ruleset/testdata/iptables-1.8.13-mangle.save"))
	b.ref = ruleset.Listing{Nft: mustRead(t, "../ruleset/testdata/nft-1.1.6-clean.json"), Mangle: mangle}
	b.root["/run/crew/uplink"] = []byte("eth0\n")
	b.root[paths.Egress()] = []byte("198.51.100.20\n")
	// The address crew-vmctl has seen, in its own state.
	b.root[paths.State("egress4")] = []byte("198.51.100.20\n")
	b.answer = func(argv []string) (string, error) {
		switch strings.Join(argv, " ") {
		case "nft -j list table inet crew":
			return b.table, nil
		case "nft -j list set inet crew site4":
			return site4JSON(b.site4), nil
		case "iptables-nft-save -t mangle":
			return mangle, nil
		case "ip -j -4 addr show dev eth0":
			return `[{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.168.64.34","prefixlen":24}]}]`, nil
		}
		if argv[0] == "systemctl" && argv[1] == "show" {
			return showing("")(argv)
		}
		return "", nil
	}
	return b
}

// site4JSON is nft's listing of site4 with these elements: a /32 is a
// bare address, as nft prints it.
func site4JSON(elems []string) string {
	var es []any
	for _, e := range elems {
		p := netip.MustParsePrefix(e)
		if p.Bits() == 32 {
			es = append(es, p.Addr().String())
		} else {
			es = append(es, map[string]any{"prefix": map[string]any{"addr": p.Addr().String(), "len": p.Bits()}})
		}
	}
	set := map[string]any{"family": "inet", "name": "site4", "table": "crew", "type": "ipv4_addr", "flags": []string{"interval"}}
	if len(es) > 0 {
		set["elem"] = es
	}
	b, _ := json.Marshal(map[string]any{"nftables": []any{map[string]any{"metainfo": map[string]any{}}, map[string]any{"set": set}}})
	return string(b)
}

func TestNftVerifyHoldsSite4(t *testing.T) {
	b := newBox(t)
	r := handle(t, server(t, b.fakeSys, time.Now()), `{"verb":"nft-verify"}`)
	if !r.OK || r.Site4 == nil || !reflect.DeepEqual(r.Site4.Egress, []string{"198.51.100.20"}) {
		t.Fatalf("%+v %+v", r, r.Site4)
	}

	for name, loaded := range map[string][]string{
		"empty":                 nil,
		"without the egress":    {"192.168.64.0/24"},
		"without the uplink's":  {"198.51.100.20/32"},
		"an old egress address": {"192.168.64.0/24", "198.51.100.99/32"},
	} {
		b := newBox(t)
		b.site4 = loaded
		r := handle(t, server(t, b.fakeSys, time.Now()), `{"verb":"nft-verify"}`)
		if r.OK || r.Error != ErrSite4NotReady {
			t.Errorf("%s: %+v", name, r)
		}
		// nft-verify only looks.
		if b.ran("nft", "-f", "-") {
			t.Errorf("%s: nft-verify changed site4", name)
		}
	}

	// More than crew-net would put there only blocks more: still ready.
	more := newBox(t)
	more.site4 = []string{"10.0.0.0/8", "192.168.0.0/16", "198.51.100.20/32", "203.0.113.0/24"}
	if r := handle(t, server(t, more.fakeSys, time.Now()), `{"verb":"nft-verify"}`); !r.OK {
		t.Fatalf("a wider set: %+v", r)
	}
}

// The agent can add an egress address to site4, never take one out: the
// addresses crew-vmctl has seen stay, in its own state, whatever the
// agent's file says later.
func TestSite4EgressIsAddOnly(t *testing.T) {
	b := newBox(t)
	s := server(t, b.fakeSys, time.Now())

	// A new address from the agent is added to the ones seen.
	b.root[paths.Egress()] = []byte("203.0.113.5\n")
	if err := s.RefreshSite4(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := string(b.root[paths.State("egress4")]); got != "198.51.100.20\n203.0.113.5\n" {
		t.Fatalf("history %q", got)
	}
	both := []string{"192.168.64.0/24", "198.51.100.20/32", "203.0.113.5/32"}

	// Another address, garbage, or no file: nothing seen goes.
	for _, body := range []string{"", "not an address\n", "2001:db8::1\n", "10.0.0.1/8\n", "203.0.113.5\n"} {
		if body == "" {
			delete(b.root, paths.Egress())
		} else {
			b.root[paths.Egress()] = []byte(body)
		}
		if err := s.RefreshSite4(t.Context()); err != nil {
			t.Fatal(err)
		}
		set, err := s.Site4(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(set, both) {
			t.Errorf("agent/egress4 %q: site4 %v", body, set)
		}
	}

	// nft-verify holds site4 to every address seen, not the agent's latest.
	b.site4 = []string{"192.168.64.0/24", "203.0.113.5/32"}
	r := handle(t, s, `{"verb":"nft-verify"}`)
	if r.OK || r.Error != ErrSite4NotReady {
		t.Fatalf("an address swapped out of site4: %+v", r)
	}
	b.site4 = both
	r = handle(t, s, `{"verb":"nft-verify"}`)
	if !r.OK || !reflect.DeepEqual(r.Site4.Egress, []string{"198.51.100.20", "203.0.113.5"}) {
		t.Fatalf("%+v %+v", r, r.Site4)
	}
}

// The agent's site4 and crew-net's timer can overlap: each runs the
// update of the addresses seen and the load of site4 under one lock, so
// neither drops an address the other just added, nor loads an older set
// over a newer one.
func TestSite4RefillsOneAtATime(t *testing.T) {
	b := newBox(t)
	b.root[paths.Egress()] = []byte("203.0.113.5\n")
	if err := server(t, b.fakeSys, time.Now()).RefreshSite4(t.Context()); err != nil {
		t.Fatal(err)
	}
	want := []string{"lock egress4", "write egress4 under egress4", "nft -f - under egress4", "unlock egress4"}
	if !reflect.DeepEqual(b.events, want) {
		t.Fatalf("%q", b.events)
	}

	// Held by another: this one waits its turn rather than going ahead.
	busy := newBox(t)
	busy.locked = "egress4"
	if err := server(t, busy.fakeSys, time.Now()).RefreshSite4(t.Context()); err == nil {
		t.Fatal("refilled site4 without the lock")
	}
	if busy.ran("nft", "-f", "-") {
		t.Fatal("loaded site4 without the lock")
	}
}

func TestSite4EgressHistoryIsBounded(t *testing.T) {
	b := newBox(t)
	var seen []string
	for i := 0; i < MaxEgress; i++ {
		seen = append(seen, fmt.Sprintf("198.51.100.%d", i+1))
	}
	b.root[paths.State("egress4")] = []byte(strings.Join(seen, "\n") + "\n")
	b.root[paths.Egress()] = []byte("203.0.113.5\n")
	s := server(t, b.fakeSys, time.Now())
	// Full: a new address isn't added, and none of the old ones goes to
	// make room (an agent adding addresses could push the real one out).
	if err := s.RefreshSite4(t.Context()); err != nil {
		t.Fatal(err)
	}
	if got := string(b.root[paths.State("egress4")]); got != strings.Join(seen, "\n")+"\n" {
		t.Fatalf("history changed: %q", got)
	}
	set, _ := s.Site4(t.Context())
	if len(set) != MaxEgress+1 {
		t.Fatalf("site4 has %d prefixes", len(set))
	}
}

// What site4 holds comes from root's side: the uplink's subnets, the
// addresses seen, and the box's extra blocks from /etc/crew-box, which
// the Ignition writes. Nothing from the agent's env.
func TestSite4IsFromRootsInputs(t *testing.T) {
	b := newBox(t)
	b.root[paths.AgentEnv()] = []byte("CREW_EXTRA_BLOCKED=1.2.3.0/24\nCREW_UPLINK=eth9\n")
	b.root[ExtraBlockedFile] = []byte("# the site's own\n192.168.64.0/26\n8.8.8.0/24, not-a-cidr\n\n")
	s := server(t, b.fakeSys, time.Now())
	set, err := s.Site4(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"8.8.8.0/24", "192.168.64.0/24", "198.51.100.20/32"}; !reflect.DeepEqual(set, want) {
		t.Fatalf("site4 %v", set)
	}
}

func TestUplinkIsRoots(t *testing.T) {
	b := newBox(t)
	b.root[paths.AgentEnv()] = []byte("CREW_UPLINK=eth9\n")
	inner := b.answer
	b.answer = func(argv []string) (string, error) {
		if strings.Join(argv, " ") == "ip -j -4 route show default" {
			return `[{"dst":"default","gateway":"192.168.64.1","dev":"eth0"}]`, nil
		}
		return inner(argv)
	}
	s := server(t, b.fakeSys, time.Now())
	if up, err := s.findUplink(t.Context()); err != nil || up != "eth0" {
		t.Fatalf("the default route's: %q %v", up, err)
	}
	b.root[UplinkFile] = []byte("enp3s0\n")
	if up, err := s.findUplink(t.Context()); err != nil || up != "enp3s0" {
		t.Fatalf("/etc/crew-box/uplink's: %q %v", up, err)
	}
	b.root[UplinkFile] = []byte("tailscale0\n")
	if _, err := s.findUplink(t.Context()); err == nil {
		t.Fatal("tailscale0 isn't an uplink")
	}
}

func TestSite4Verb(t *testing.T) {
	b := newBox(t)
	if r := handle(t, server(t, b.fakeSys, time.Now()), `{"verb":"site4"}`); !r.OK {
		t.Fatalf("%+v", r)
	}
	want := "flush set inet crew site4\nadd element inet crew site4 { 192.168.64.0/24, 198.51.100.20/32 }\n"
	if got := b.stdins[len(b.stdins)-1]; got != want {
		t.Fatalf("%q", got)
	}
	if _, err := ParseRequest([]byte(`{"verb":"site4","lease_index":3}`), testNet(t)); err == nil {
		t.Fatal("site4 takes no arguments")
	}
}

func TestLoadedSite4(t *testing.T) {
	listing := `{"nftables":[{"metainfo":{}},{"set":{"name":"site4","elem":[` +
		`{"prefix":{"addr":"192.168.64.0","len":24}},"198.51.100.20",` +
		`{"range":["203.0.113.0","203.0.113.255"]}]}}]}`
	got, err := loadedSite4([]byte(listing))
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"192.168.64.0/24", "192.168.64.128/25", "198.51.100.20/32", "203.0.113.0/24", "203.0.113.7/32"} {
		if !covered(got, netip.MustParsePrefix(p)) {
			t.Errorf("%s: not covered by %v", p, got)
		}
	}
	for _, p := range []string{"192.168.0.0/16", "198.51.100.21/32", "203.0.112.0/23"} {
		if covered(got, netip.MustParsePrefix(p)) {
			t.Errorf("%s: covered", p)
		}
	}
	if _, err := loadedSite4([]byte(`{"nftables":[]}`)); err == nil {
		t.Error("no set: want an error")
	}
}
