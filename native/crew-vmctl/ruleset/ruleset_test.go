package ruleset

import (
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
// element, as a box with a VM has.
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
