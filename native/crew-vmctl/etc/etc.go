// Package etc is the agent tarball's etc/ for Firecracker boxes: the
// nftables ruleset (§14.2), the connection cap and crew-net's and
// crew-vmctl's systemd units. crew-vmctl embeds the rules, so what it
// loads and what it verifies are one copy, the one in its own binary.
package etc

import _ "embed"

// NftConf is etc/nft.conf, with $UPLINK still to fill in.
//
//go:embed nft.conf
var NftConf string

// ConnlimitRules is etc/connlimit.rules, for iptables-nft-restore.
//
//go:embed connlimit.rules
var ConnlimitRules string
