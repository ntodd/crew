package ruleset

import (
	"fmt"
	"strings"
)

// The connection cap lives in iptables-nft's mangle table, which Crew
// shares: Tailscale 1.104 keeps connmark rules there, and anything else on
// the box may add its own. Crew owns two things in it, and only those:
//
//   - its chains (CREW-*), which must be exactly the shipped ones;
//   - the first rules of each built-in chain the shipped file adds to
//     (the jumps into CREW-CONNLIMIT from INPUT and FORWARD), so nothing
//     can accept a VM's packet before the cap counts it.
//
// Rules after the jumps, in the other built-in chains, or in other chains
// are someone else's, and don't count. Built-in chains' policies stay the
// shipped ones.

const crewChainPrefix = "CREW-"

var builtinChains = map[string]bool{
	"PREROUTING": true, "INPUT": true, "FORWARD": true, "OUTPUT": true, "POSTROUTING": true,
}

// mangle is a parsed iptables-save of the mangle table, or of
// etc/connlimit.rules.
type mangle struct {
	chains   []string          // in declaration order
	policies map[string]string // "ACCEPT", or "-" for a user chain
	rules    map[string][]string
}

// parseMangle reads `iptables-nft-save -t mangle` output. Empty input is
// an empty table (nothing loaded). Comments and counters don't count.
func parseMangle(s string) (mangle, error) {
	m := mangle{policies: map[string]string{}, rules: map[string][]string{}}
	in, committed := false, false
	for _, l := range strings.Split(normalizeSave(s), "\n") {
		switch {
		case l == "":
		case l == "*mangle":
			in = true
		case strings.HasPrefix(l, "*"):
			return m, fmt.Errorf("table %s: only mangle is Crew's to load", l[1:])
		case !in:
			return m, fmt.Errorf("%q outside *mangle", l)
		case l == "COMMIT":
			committed = true
		case strings.HasPrefix(l, ":"):
			f := strings.Fields(l[1:])
			if len(f) < 2 {
				return m, fmt.Errorf("chain line %q", l)
			}
			m.chains = append(m.chains, f[0])
			m.policies[f[0]] = f[1]
		case strings.HasPrefix(l, "-A "):
			f := strings.Fields(l)
			if len(f) < 2 {
				return m, fmt.Errorf("rule %q", l)
			}
			if _, ok := m.policies[f[1]]; !ok {
				return m, fmt.Errorf("rule %q: chain %s isn't declared", l, f[1])
			}
			m.rules[f[1]] = append(m.rules[f[1]], l)
		default:
			return m, fmt.Errorf("line %q", l)
		}
	}
	if in && !committed {
		return m, fmt.Errorf("no COMMIT")
	}
	return m, nil
}

// MangleScript is crew-net's load of etc/connlimit.rules, for
// `iptables-nft-restore --noflush`: one transaction that sets the
// built-in chains' policies, empties and refills Crew's chains, and puts
// the jumps first in their chains, deleting every copy current (the box's
// `iptables-nft-save -t mangle`) has first. A -D of a rule that isn't
// there fails the whole load, so the count is current's. Nothing else in
// current is touched.
func MangleScript(rules, current string) (string, error) {
	want, err := parseMangle(rules)
	if err != nil {
		return "", fmt.Errorf("connlimit.rules: %w", err)
	}
	if len(want.chains) == 0 {
		return "", fmt.Errorf("connlimit.rules: no *mangle table")
	}
	have, err := parseMangle(current)
	if err != nil {
		return "", fmt.Errorf("the box's mangle table: %w", err)
	}

	var b strings.Builder
	b.WriteString("*mangle\n")
	for _, c := range want.chains {
		if !builtinChains[c] && !strings.HasPrefix(c, crewChainPrefix) {
			return "", fmt.Errorf("connlimit.rules: chain %s isn't Crew's (%s*)", c, crewChainPrefix)
		}
		fmt.Fprintf(&b, ":%s %s [0:0]\n", c, want.policies[c])
	}
	for _, c := range want.chains {
		if !builtinChains[c] {
			continue
		}
		for _, r := range want.rules[c] {
			for _, h := range have.rules[c] {
				if h == r {
					b.WriteString("-D" + strings.TrimPrefix(r, "-A") + "\n")
				}
			}
		}
	}
	for _, c := range want.chains {
		if !builtinChains[c] {
			continue
		}
		for i, r := range want.rules[c] {
			spec := strings.TrimPrefix(r, "-A "+c)
			fmt.Fprintf(&b, "-I %s %d%s\n", c, i+1, spec)
		}
	}
	for _, c := range want.chains {
		if builtinChains[c] {
			continue
		}
		for _, r := range want.rules[c] {
			b.WriteString(r + "\n")
		}
	}
	b.WriteString("COMMIT\n")
	return b.String(), nil
}

// compareMangle reports how the box's mangle table falls short of Crew's
// part of the reference (see the top of this file).
func compareMangle(refSave, gotSave string) []string {
	ref, err := parseMangle(refSave)
	if err != nil {
		return []string{"the reference mangle table: " + err.Error()}
	}
	got, err := parseMangle(gotSave)
	if err != nil {
		return []string{"the box's mangle table: " + err.Error()}
	}
	if len(ref.chains) == 0 {
		return []string{"the reference mangle table is empty"}
	}
	var diffs []string
	for _, c := range ref.chains {
		p, ok := got.policies[c]
		if !ok {
			diffs = append(diffs, fmt.Sprintf("mangle chain %s is missing", c))
			continue
		}
		if p != ref.policies[c] {
			diffs = append(diffs, fmt.Sprintf("mangle chain %s: policy %s, not %s", c, p, ref.policies[c]))
		}
		want, have := ref.rules[c], got.rules[c]
		if builtinChains[c] {
			if len(have) < len(want) || !equal(have[:len(want)], want) {
				diffs = append(diffs, fmt.Sprintf("mangle chain %s doesn't start with Crew's rules:\n%s\n--- the box has ---\n%s",
					c, strings.Join(want, "\n"), strings.Join(have, "\n")))
			}
		} else if !equal(have, want) {
			diffs = append(diffs, fmt.Sprintf("mangle chain %s differs:\n%s\n--- the box has ---\n%s",
				c, strings.Join(want, "\n"), strings.Join(have, "\n")))
		}
	}
	for _, c := range got.chains {
		if _, ok := ref.policies[c]; ok {
			continue
		}
		if strings.HasPrefix(c, crewChainPrefix) {
			diffs = append(diffs, fmt.Sprintf("mangle chain %s isn't one Crew ships", c))
		}
		if builtinChains[c] && got.policies[c] != "ACCEPT" {
			diffs = append(diffs, fmt.Sprintf("mangle chain %s: policy %s", c, got.policies[c]))
		}
	}
	return diffs
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
