package vmctl

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
	"strings"
)

// ErrSite4NotReady: site4 doesn't hold what crew-net would put there.
const ErrSite4NotReady = "site4_not_ready"

// lastEgressFile is the last valid egress address crew-vmctl read from
// the agent's agent/egress4. Root's, so a missing or broken agent file
// never drops the address from site4.
const lastEgressFile = "/run/crew/egress4"

// Site4Status is what nft-verify reports about site4.
type Site4Status struct {
	Egress   string   `json:"egress,omitempty"` // the egress address in it, if crew-vmctl knows one
	Prefixes []string `json:"prefixes"`         // what crew-net puts there
}

// Site4 is the set crew-net keeps in site4 (§14.2): the uplink's
// connected subnets, the site's egress address (the agent's
// agent/egress4, or the last valid one) and CREW_EXTRA_BLOCKED. A prefix
// inside another is left out, since nft refuses overlapping intervals.
func (s *Server) Site4(ctx context.Context) ([]string, error) {
	set, _, err := s.site4(ctx)
	return set, err
}

func (s *Server) site4(ctx context.Context) ([]string, string, error) {
	up, err := s.uplink()
	if err != nil {
		return nil, "", err
	}
	var prefixes []netip.Prefix
	out, err := s.Sys.Run(ctx, nil, "ip", "-j", "-4", "addr", "show", "dev", up)
	if err != nil {
		return nil, "", err
	}
	var links []struct {
		AddrInfo []struct {
			Local     string `json:"local"`
			PrefixLen int    `json:"prefixlen"`
		} `json:"addr_info"`
	}
	if err := json.Unmarshal(out, &links); err != nil {
		return nil, "", fmt.Errorf("ip addr: %w", err)
	}
	for _, l := range links {
		for _, a := range l.AddrInfo {
			if p, err := netip.ParsePrefix(fmt.Sprintf("%s/%d", a.Local, a.PrefixLen)); err == nil && p.Addr().Is4() {
				prefixes = append(prefixes, p.Masked())
			}
		}
	}
	egress := s.egress()
	if egress.IsValid() {
		prefixes = append(prefixes, netip.PrefixFrom(egress, 32))
	}
	for _, c := range strings.Split(s.agentEnv()["CREW_EXTRA_BLOCKED"], ",") {
		if p, err := netip.ParsePrefix(strings.TrimSpace(c)); err == nil && p.Addr().Is4() {
			prefixes = append(prefixes, p.Masked())
		}
	}
	e := ""
	if egress.IsValid() {
		e = egress.String()
	}
	return disjoint(prefixes), e, nil
}

// egress is the agent's agent/egress4 when it holds one IPv4 address,
// else the last one that did.
func (s *Server) egress() netip.Addr {
	parse := func(path string) netip.Addr {
		body, err := s.Sys.ReadFile(path, 64)
		if err != nil {
			return netip.Addr{}
		}
		a, err := netip.ParseAddr(strings.TrimSpace(string(body)))
		if err != nil || !a.Is4() {
			return netip.Addr{}
		}
		return a
	}
	if a := parse(s.Paths.Egress()); a.IsValid() {
		return a
	}
	return parse(lastEgressFile)
}

func disjoint(ps []netip.Prefix) []string {
	// Widest first, so a prefix inside one already kept is skipped.
	sort.Slice(ps, func(i, j int) bool {
		if ps[i].Bits() != ps[j].Bits() {
			return ps[i].Bits() < ps[j].Bits()
		}
		return ps[i].Addr().Less(ps[j].Addr())
	})
	var kept []netip.Prefix
	for _, p := range ps {
		if !covered(kept, p) {
			kept = append(kept, p)
		}
	}
	sort.Slice(kept, func(i, j int) bool { return kept[i].Addr().Less(kept[j].Addr()) })
	out := make([]string, len(kept))
	for i, p := range kept {
		out[i] = p.String()
	}
	return out
}

// RefreshSite4 flushes and refills site4 in one nft transaction (the
// `site4` verb, crew-net's timer), and keeps the egress address it used.
func (s *Server) RefreshSite4(ctx context.Context) error {
	set, egress, err := s.site4(ctx)
	if err != nil {
		return err
	}
	script := "flush set inet crew site4\n"
	if len(set) > 0 {
		script += "add element inet crew site4 { " + strings.Join(set, ", ") + " }\n"
	}
	if _, err := s.Sys.Run(ctx, []byte(script), "nft", "-f", "-"); err != nil {
		return err
	}
	if egress != "" {
		return s.Sys.WriteFile(lastEgressFile, []byte(egress+"\n"))
	}
	return nil
}

// site4Ready checks that site4 holds everything crew-net puts there.
// More is fine (it only blocks more); anything missing isn't.
func (s *Server) site4Ready(ctx context.Context) (*Site4Status, error) {
	want, egress, err := s.site4(ctx)
	if err != nil {
		return nil, fail(ErrSite4NotReady, "%v", err)
	}
	out, err := s.Sys.Run(ctx, nil, "nft", "-j", "list", "set", "inet", "crew", "site4")
	if err != nil {
		return nil, fail(ErrSite4NotReady, "%v", err)
	}
	have, err := loadedSite4(out)
	if err != nil {
		return nil, fail(ErrSite4NotReady, "%v", err)
	}
	var missing []string
	for _, w := range want {
		if !covered(have, netip.MustParsePrefix(w)) {
			missing = append(missing, w)
		}
	}
	if len(missing) > 0 {
		return nil, fail(ErrSite4NotReady, "site4 is missing %s", strings.Join(missing, ", "))
	}
	return &Site4Status{Egress: egress, Prefixes: want}, nil
}

// loadedSite4 reads `nft -j list set inet crew site4`: prefixes, bare
// addresses and ranges, each as the prefixes that cover it exactly.
func loadedSite4(body []byte) ([]netip.Prefix, error) {
	var doc struct {
		Nftables []struct {
			Set *struct {
				Name string            `json:"name"`
				Elem []json.RawMessage `json:"elem"`
			} `json:"set"`
		} `json:"nftables"`
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&doc); err != nil {
		return nil, err
	}
	for _, o := range doc.Nftables {
		if o.Set == nil || o.Set.Name != "site4" {
			continue
		}
		var out []netip.Prefix
		for _, raw := range o.Set.Elem {
			var addr string
			var e struct {
				Prefix *struct {
					Addr string `json:"addr"`
					Len  int    `json:"len"`
				} `json:"prefix"`
				Range []string `json:"range"`
			}
			switch {
			case json.Unmarshal(raw, &addr) == nil:
				if a, err := netip.ParseAddr(addr); err == nil {
					out = append(out, netip.PrefixFrom(a, 32))
				}
			case json.Unmarshal(raw, &e) == nil && e.Prefix != nil:
				if p, err := netip.ParsePrefix(fmt.Sprintf("%s/%d", e.Prefix.Addr, e.Prefix.Len)); err == nil {
					out = append(out, p.Masked())
				}
			case len(e.Range) == 2:
				lo, err1 := netip.ParseAddr(e.Range[0])
				hi, err2 := netip.ParseAddr(e.Range[1])
				if err1 == nil && err2 == nil {
					out = append(out, rangePrefixes(lo, hi)...)
				}
			}
		}
		return out, nil
	}
	return nil, fmt.Errorf("site4 isn't loaded")
}

// rangePrefixes splits lo..hi into the prefixes that cover it exactly.
func rangePrefixes(lo, hi netip.Addr) []netip.Prefix {
	var out []netip.Prefix
	for !hi.Less(lo) {
		bits := 32
		for bits > 0 {
			p := netip.PrefixFrom(lo, bits-1).Masked()
			last := lastAddr(p)
			if p.Addr() != lo || hi.Less(last) {
				break
			}
			bits--
		}
		p := netip.PrefixFrom(lo, bits)
		out = append(out, p)
		next := lastAddr(p).Next()
		if !next.IsValid() || next.Is6() {
			break
		}
		lo = next
	}
	return out
}

func lastAddr(p netip.Prefix) netip.Addr {
	a := p.Masked().Addr().As4()
	n := uint32(a[0])<<24 | uint32(a[1])<<16 | uint32(a[2])<<8 | uint32(a[3])
	n |= (uint32(1) << (32 - p.Bits())) - 1
	if p.Bits() == 0 {
		n = ^uint32(0)
	}
	return netip.AddrFrom4([4]byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)})
}

// covered reports whether p lies inside one of have.
func covered(have []netip.Prefix, p netip.Prefix) bool {
	for _, h := range have {
		if h.Bits() <= p.Bits() && h.Contains(p.Addr()) {
			return true
		}
	}
	return false
}
