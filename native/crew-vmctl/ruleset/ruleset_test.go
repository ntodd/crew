package ruleset

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/ntodd/crew/native/crew-vmctl/etc"
)

// testdata holds `nft -j list table inet crew` and `iptables-nft-save -t
// mangle` as nftables 1.0.6 / iptables 1.8.9 (Debian bookworm) and
// nftables 1.1.6 / iptables 1.8.13 (Flatcar 4757.2.3) print them, after
// loading etc/ with UPLINK=eth0. "busy" adds a vm_pairs and a site4
// element, as a box with a VM has. iptables-1.8.13-mangle-tailscale.save
// is the mangle table after Tailscale 1.104.5 added its two connmark
// rules to it (iptables-nft -t mangle -A, as tailscaled does), recorded
// on Fedora rawhide's iptables 1.8.13.
func read(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func listing(t *testing.T, nft, ipt, kind string) Listing {
	return Listing{Nft: read(t, "nft-"+nft+"-"+kind+".json"), Mangle: string(read(t, "iptables-"+ipt+"-mangle.save"))}
}

// The listings must be of the rules crew-vmctl ships: change etc/ and
// they're recorded again (with the hash of what they were recorded from).
func TestTestdataIsOfTheShippedRules(t *testing.T) {
	sum := sha256.Sum256([]byte(etc.NftConf + etc.ConnlimitRules))
	want := strings.TrimSpace(string(read(t, "rules.sha256")))
	if got := hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("testdata was recorded from other rules (%s, now %s): record it again (README)", want, got)
	}
}

// From a VM, nothing on the host but the service address answers (§14.4):
// every rule in the input chain that accepts from crewt* names it.
func TestGuestsReachOnlyTheServiceAddress(t *testing.T) {
	for _, name := range []string{"nft-1.0.6-clean.json", "nft-1.1.6-clean.json"} {
		var doc struct {
			Nftables []map[string]json.RawMessage `json:"nftables"`
		}
		if err := json.Unmarshal(read(t, name), &doc); err != nil {
			t.Fatal(err)
		}
		type match struct {
			Left struct {
				Meta    struct{ Key string }             `json:"meta"`
				Payload struct{ Protocol, Field string } `json:"payload"`
			} `json:"left"`
			Right any `json:"right"`
		}
		accepts := 0
		for _, o := range doc.Nftables {
			raw, ok := o["rule"]
			if !ok {
				continue
			}
			var r struct {
				Chain string                       `json:"chain"`
				Expr  []map[string]json.RawMessage `json:"expr"`
			}
			if err := json.Unmarshal(raw, &r); err != nil {
				t.Fatal(err)
			}
			fromVMs, accept, toService := false, false, false
			for _, e := range r.Expr {
				if _, ok := e["accept"]; ok {
					accept = true
				}
				var m match
				if b, ok := e["match"]; ok && json.Unmarshal(b, &m) == nil {
					fromVMs = fromVMs || (m.Left.Meta.Key == "iifname" && m.Right == "crewt*")
					toService = toService || (m.Left.Payload.Protocol == "ip" && m.Left.Payload.Field == "daddr" && m.Right == "10.199.0.1")
				}
			}
			if r.Chain != "input" || !fromVMs || !accept {
				continue
			}
			accepts++
			if !toService {
				t.Errorf("%s: an input rule accepts from VMs without naming 10.199.0.1: %s", name, raw)
			}
		}
		if accepts != 3 {
			t.Errorf("%s: %d accepting input rules, want 3", name, accepts)
		}
	}
}

func TestTheLoadedRulesetMatchesItself(t *testing.T) {
	for _, v := range [][2]string{{"1.0.6", "1.8.9"}, {"1.1.6", "1.8.13"}} {
		// The reference is a fresh load; the box's table has elements in
		// the sets crew-vmctl and crew-net fill, which don't count.
		if err := Compare(listing(t, v[0], v[1], "clean"), listing(t, v[0], v[1], "busy")); err != nil {
			t.Errorf("nft %s: %v", v[0], err)
		}
	}
}

func TestVersionsDifferInOrderOnly(t *testing.T) {
	// 1.1.6 lists chains before sets; the comparison doesn't care.
	if err := Compare(listing(t, "1.0.6", "1.8.9", "clean"), listing(t, "1.1.6", "1.8.13", "busy")); err != nil {
		t.Fatal(err)
	}
}

// mutate edits a recorded listing's objects and returns it re-encoded.
func mutate(t *testing.T, body []byte, f func(objs []map[string]any) []map[string]any) []byte {
	t.Helper()
	var doc struct {
		Nftables []map[string]any `json:"nftables"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	doc.Nftables = f(doc.Nftables)
	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func find(objs []map[string]any, kind, name string) map[string]any {
	for _, o := range objs {
		if v, ok := o[kind].(map[string]any); ok && (name == "" || v["name"] == name) {
			return v
		}
	}
	return nil
}

func rules(objs []map[string]any, chain string) []int {
	var idx []int
	for i, o := range objs {
		if r, ok := o["rule"].(map[string]any); ok && r["chain"] == chain {
			idx = append(idx, i)
		}
	}
	return idx
}

func TestAnyChangeIsAMismatch(t *testing.T) {
	ref := listing(t, "1.1.6", "1.8.13", "clean")
	cases := map[string]func(objs []map[string]any) []map[string]any{
		"a rule gone": func(objs []map[string]any) []map[string]any {
			i := rules(objs, "pre")[2] // anti-spoofing
			return append(objs[:i], objs[i+1:]...)
		},
		"rules reordered": func(objs []map[string]any) []map[string]any {
			r := rules(objs, "forward")
			objs[r[0]], objs[r[2]] = objs[r[2]], objs[r[0]]
			return objs
		},
		"an accept added": func(objs []map[string]any) []map[string]any {
			r := objs[rules(objs, "input")[0]]["rule"].(map[string]any)
			extra := map[string]any{"rule": map[string]any{"family": "inet", "table": "crew", "chain": "input",
				"expr": []any{map[string]any{"accept": nil}}}}
			_ = r
			return append(objs, extra)
		},
		"a policy changed": func(objs []map[string]any) []map[string]any {
			find(objs, "chain", "forward")["policy"] = "accept"
			return objs
		},
		"a hook priority changed": func(objs []map[string]any) []map[string]any {
			find(objs, "chain", "pre")["prio"] = 0
			return objs
		},
		"blocked4 lost a range": func(objs []map[string]any) []map[string]any {
			s := find(objs, "set", "blocked4")
			s["elem"] = s["elem"].([]any)[1:]
			return objs
		},
		"blocked4 gained a range": func(objs []map[string]any) []map[string]any {
			s := find(objs, "set", "blocked4")
			s["elem"] = append(s["elem"].([]any), map[string]any{"prefix": map[string]any{"addr": "8.8.8.0", "len": 24}})
			return objs
		},
		"another uplink": func(objs []map[string]any) []map[string]any {
			i := rules(objs, "forward")[2]
			b, _ := json.Marshal(objs[i])
			var o map[string]any
			_ = json.Unmarshal([]byte(strings.Replace(string(b), `"eth0"`, `"tailscale0"`, 1)), &o)
			objs[i] = o
			return objs
		},
		"a chain added": func(objs []map[string]any) []map[string]any {
			return append(objs, map[string]any{"chain": map[string]any{"family": "inet", "table": "crew", "name": "extra"}})
		},
		"a set added": func(objs []map[string]any) []map[string]any {
			return append(objs, map[string]any{"set": map[string]any{"family": "inet", "table": "crew", "name": "allow", "type": "ipv4_addr"}})
		},
		"a chain gone": func(objs []map[string]any) []map[string]any {
			for i, o := range objs {
				if c, ok := o["chain"].(map[string]any); ok && c["name"] == "post" {
					return append(objs[:i], objs[i+1:]...)
				}
			}
			return objs
		},
		"vm_pairs retyped": func(objs []map[string]any) []map[string]any {
			find(objs, "set", "vm_pairs")["type"] = "ipv4_addr"
			return objs
		},
	}
	for name, f := range cases {
		got := Listing{Nft: mutate(t, read(t, "nft-1.1.6-busy.json"), f), Mangle: ref.Mangle}
		if err := Compare(ref, got); err == nil {
			t.Errorf("%s: no mismatch", name)
		}
	}
}

func TestTheTableMustBeThere(t *testing.T) {
	ref := listing(t, "1.1.6", "1.8.13", "clean")
	if err := Compare(ref, Listing{Nft: []byte(`{"nftables":[{"metainfo":{}}]}`), Mangle: ref.Mangle}); err == nil {
		t.Fatal("an empty listing matched")
	}
	if err := Compare(ref, Listing{Nft: []byte(`not json`), Mangle: ref.Mangle}); err == nil {
		t.Fatal("garbage matched")
	}
}

func TestTheConnectionCapMustMatch(t *testing.T) {
	ref := listing(t, "1.1.6", "1.8.13", "clean")
	base := string(read(t, "iptables-1.8.13-mangle.save"))
	for name, m := range map[string]string{
		"a higher cap":       strings.Replace(base, "--connlimit-above 2048", "--connlimit-above 65536", 1),
		"no jump on forward": strings.Replace(base, "-A FORWARD -i crewt+ -j CREW-CONNLIMIT\n", "", 1),
		"an accept first": strings.Replace(base, "-A INPUT -i crewt+ -j CREW-CONNLIMIT",
			"-A INPUT -i crewt+ -j ACCEPT\n-A INPUT -i crewt+ -j CREW-CONNLIMIT", 1),
		"a policy drop":  strings.Replace(base, ":OUTPUT ACCEPT", ":OUTPUT DROP", 1),
		"nothing loaded": "",
		"someone else's rule before the jump": strings.Replace(base, "-A FORWARD -i crewt+ -j CREW-CONNLIMIT",
			"-A FORWARD -j MARK --set-xmark 0x1/0xffffffff\n-A FORWARD -i crewt+ -j CREW-CONNLIMIT", 1),
		"an extra rule in Crew's chain": strings.Replace(base, "COMMIT",
			"-A CREW-CONNLIMIT -j RETURN\nCOMMIT", 1),
		"a Crew chain it doesn't ship": strings.Replace(base, "COMMIT",
			":CREW-OTHER - [0:0]\nCOMMIT", 1),
	} {
		got := Listing{Nft: ref.Nft, Mangle: m}
		if err := Compare(ref, got); err == nil {
			t.Errorf("%s: no mismatch", name)
		}
	}
	// Counters and the save's timestamps don't count.
	counted := strings.Replace(base, ":INPUT ACCEPT [0:0]", ":INPUT ACCEPT [1234:567890]", 1)
	counted = strings.Replace(counted, "Wed Nov  4", "Thu Nov  5", -1)
	if err := Compare(ref, Listing{Nft: ref.Nft, Mangle: counted}); err != nil {
		t.Fatal(err)
	}
}

// Crew owns its chain and the first rules of mangle's INPUT and FORWARD,
// not the table: Tailscale 1.104 keeps its connmarks there.
func TestTheMangleTableIsShared(t *testing.T) {
	ref := listing(t, "1.1.6", "1.8.13", "clean")
	base := string(read(t, "iptables-1.8.13-mangle.save"))
	for name, m := range map[string]string{
		"Tailscale's connmarks": string(read(t, "iptables-1.8.13-mangle-tailscale.save")),
		"a rule after the jump": strings.Replace(base, "-A FORWARD -i crewt+ -j CREW-CONNLIMIT",
			"-A FORWARD -i crewt+ -j CREW-CONNLIMIT\n-A FORWARD -j MARK --set-xmark 0x1/0xffffffff", 1),
		"someone else's chain": strings.Replace(base, "COMMIT",
			":ts-mangle - [0:0]\n-A ts-mangle -j RETURN\nCOMMIT", 1),
	} {
		if err := Compare(ref, Listing{Nft: ref.Nft, Mangle: m}); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// crew-net's load: Crew's chain refilled and its jumps first, in one
// iptables-nft-restore --noflush, with everyone else's rules left alone.
func TestMangleScript(t *testing.T) {
	jumps := "-I INPUT 1 -i crewt+ -j CREW-CONNLIMIT\n-I FORWARD 1 -i crewt+ -j CREW-CONNLIMIT\n"
	head := "*mangle\n:PREROUTING ACCEPT [0:0]\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n" +
		":OUTPUT ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n:CREW-CONNLIMIT - [0:0]\n"
	tail := "-A CREW-CONNLIMIT -m conntrack --ctstate NEW -m connlimit --connlimit-above 2048 " +
		"--connlimit-mask 32 --connlimit-saddr -j DROP\nCOMMIT\n"

	// Nothing there yet: nothing to delete.
	got, err := MangleScript(etc.ConnlimitRules, "")
	if err != nil {
		t.Fatal(err)
	}
	if want := head + jumps + tail; got != want {
		t.Fatalf("fresh:\n%s\nwant:\n%s", got, want)
	}

	// Loaded before, with Tailscale's rules since and a stray second jump:
	// every copy of a jump goes (a -D of one that isn't there fails the
	// whole load), and nothing of Tailscale's does.
	box := strings.Replace(string(read(t, "iptables-1.8.13-mangle-tailscale.save")),
		"-A FORWARD -i crewt+ -j CREW-CONNLIMIT", "-A FORWARD -i crewt+ -j CREW-CONNLIMIT\n-A FORWARD -i crewt+ -j CREW-CONNLIMIT", 1)
	got, err = MangleScript(etc.ConnlimitRules, box)
	if err != nil {
		t.Fatal(err)
	}
	deletes := "-D INPUT -i crewt+ -j CREW-CONNLIMIT\n-D FORWARD -i crewt+ -j CREW-CONNLIMIT\n-D FORWARD -i crewt+ -j CREW-CONNLIMIT\n"
	if want := head + deletes + jumps + tail; got != want {
		t.Fatalf("loaded:\n%s\nwant:\n%s", got, want)
	}

	for name, rules := range map[string]string{
		"no table":                "-A INPUT -j ACCEPT\nCOMMIT\n",
		"another table":           "*filter\n:INPUT ACCEPT [0:0]\nCOMMIT\n",
		"no commit":               "*mangle\n:INPUT ACCEPT [0:0]\n",
		"a rule in no chain":      "*mangle\n-A NOWHERE -j ACCEPT\nCOMMIT\n",
		"a chain that isn't ours": "*mangle\n:ts-x - [0:0]\nCOMMIT\n",
	} {
		if _, err := MangleScript(rules, ""); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
}

func TestLoadScriptReplacesTheTableAtomically(t *testing.T) {
	s, err := LoadScript(etc.NftConf, "eth0")
	if err != nil {
		t.Fatal(err)
	}
	head := "define UPLINK = \"eth0\"\ntable inet crew\ndelete table inet crew\n"
	if !strings.HasPrefix(s, head) || !strings.HasSuffix(s, etc.NftConf) {
		t.Fatalf("script:\n%.200s", s)
	}
}

func TestUplinkNames(t *testing.T) {
	for _, ok := range []string{"eth0", "enp3s0", "ens5", "bond0.100", "wlan_0", "abcdefghijklmno"} {
		if err := CheckUplink(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "lo", "crew0", "crewt3", "crewt", `eth0"; flush ruleset; "`, "eth0 ", "-eth0",
		"abcdefghijklmnop", "eth/0", "eth*", "tailscale0", "docker0"} {
		if err := CheckUplink(bad); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
}
