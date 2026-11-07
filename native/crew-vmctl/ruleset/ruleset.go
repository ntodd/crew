// Package ruleset loads and verifies Crew's packet filter (§14.2): the
// `inet crew` nftables table (etc/nft.conf) and the connection cap in
// iptables-nft's mangle table (etc/connlimit.rules).
//
// Verification compares what the kernel has with a reference: the same
// files loaded into a fresh network namespace by the same nft and
// iptables binaries, then listed the same way. That holds the box to the
// shipped rules without depending on how a given nft version prints
// them: versions order objects differently, so objects are compared by
// kind and name, and rules in order within their chain. Handles,
// counters and the elements of the sets filled at runtime (vm_pairs and
// site4) don't count. Anything else does: a rule, a policy, a priority,
// a blocked4 range, an extra chain or set.
//
// The mangle table is shared (mangle.go): only Crew's chains and the
// jumps into them, first in their built-in chains, are held to the
// reference.
package ruleset

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Table is Crew's nftables table.
const Table = "inet crew"

// DynamicSets are the sets whose elements change at runtime.
var DynamicSets = []string{"vm_pairs", "site4"}

// Listing is one view of the rules: `nft -j list table inet crew` and
// `iptables-nft-save -t mangle`.
type Listing struct {
	Nft    []byte
	Mangle string
}

var ifnameRe = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9_.-]{0,14}\z`)

// CheckUplink accepts an interface name that can be the uplink: not
// loopback, not Crew's own, not the tailnet's or Docker's.
func CheckUplink(name string) error {
	if !ifnameRe.MatchString(name) {
		return fmt.Errorf("uplink %q: not an interface name", name)
	}
	for _, p := range []string{"crew", "tailscale", "docker"} {
		if strings.HasPrefix(name, p) {
			return fmt.Errorf("uplink %q: can't be a %s interface", name, p)
		}
	}
	if name == "lo" {
		return fmt.Errorf("uplink can't be loopback")
	}
	return nil
}

// LoadScript is the nft script that replaces the table with nft.conf in
// one transaction: it creates the table if it's missing, so the delete
// can't fail, then defines it again.
func LoadScript(nftConf, uplink string) (string, error) {
	if err := CheckUplink(uplink); err != nil {
		return "", err
	}
	return fmt.Sprintf("define UPLINK = %q\ntable inet crew\ndelete table inet crew\n", uplink) + nftConf, nil
}

// Compare reports how got differs from ref, or nil.
func Compare(ref, got Listing) error {
	want, err := normalizeNft(ref.Nft)
	if err != nil {
		return fmt.Errorf("the reference listing: %w", err)
	}
	have, err := normalizeNft(got.Nft)
	if err != nil {
		return fmt.Errorf("the box's listing: %w", err)
	}
	diffs := diff(want, have)
	diffs = append(diffs, compareMangle(ref.Mangle, got.Mangle)...)
	if len(diffs) == 0 {
		return nil
	}
	if len(diffs) > 5 {
		diffs = append(diffs[:5], fmt.Sprintf("and %d more", len(diffs)-5))
	}
	return fmt.Errorf("%s", strings.Join(diffs, "; "))
}

// normalizeNft maps each object to its canonical JSON: keyed by kind and
// name, rules by chain and position.
func normalizeNft(body []byte) (map[string]string, error) {
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	out := map[string]string{}
	pos := map[string]int{}
	tables := 0
	for _, item := range doc.Nftables {
		if len(item) != 1 {
			return nil, fmt.Errorf("an object with %d kinds", len(item))
		}
		for kind, raw := range item {
			if kind == "metainfo" {
				continue
			}
			var obj map[string]any
			d := json.NewDecoder(bytes.NewReader(raw))
			d.UseNumber()
			if err := d.Decode(&obj); err != nil {
				return nil, fmt.Errorf("%s: %w", kind, err)
			}
			delete(obj, "handle")
			name, _ := obj["name"].(string)
			key := kind + " " + name
			switch kind {
			case "table":
				tables++
			case "set", "map":
				if dynamic(name) {
					delete(obj, "elem")
				}
			case "rule":
				chain, _ := obj["chain"].(string)
				key = fmt.Sprintf("rule %s #%d", chain, pos[chain])
				pos[chain]++
			}
			canon, err := json.Marshal(obj) // map keys sorted
			if err != nil {
				return nil, err
			}
			if _, dup := out[key]; dup {
				return nil, fmt.Errorf("%s listed twice", key)
			}
			out[key] = string(canon)
		}
	}
	if tables != 1 {
		return nil, fmt.Errorf("table %s isn't loaded", Table)
	}
	return out, nil
}

func dynamic(set string) bool {
	for _, s := range DynamicSets {
		if s == set {
			return true
		}
	}
	return false
}

func diff(want, have map[string]string) []string {
	var keys []string
	seen := map[string]bool{}
	for k := range want {
		keys = append(keys, k)
		seen[k] = true
	}
	for k := range have {
		if !seen[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var out []string
	for _, k := range keys {
		w, inWant := want[k]
		h, inHave := have[k]
		switch {
		case !inHave:
			out = append(out, k+" is missing")
		case !inWant:
			out = append(out, k+" is extra: "+clip(h))
		case w != h:
			out = append(out, k+" differs: "+clip(h))
		}
	}
	return out
}

func clip(s string) string {
	if len(s) > 300 {
		return s[:300] + "…"
	}
	return s
}

var counters = regexp.MustCompile(`\[\d+:\d+\]`)

// normalizeSave drops iptables-save's comments (its timestamps) and
// packet counters.
func normalizeSave(s string) string {
	var lines []string
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		lines = append(lines, counters.ReplaceAllString(l, "[0:0]"))
	}
	return strings.Join(lines, "\n")
}
