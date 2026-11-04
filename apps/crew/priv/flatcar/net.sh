#!/bin/sh
# The box's service address and firewall (docs/crew_spec.md §12.2, §14),
# from crew-net.service once at boot: the crew0 dummy interface with
# 10.199.0.1/32, where crew_cache and the guest API listen, then the
# ruleset the agent's release ships, loaded once. Nothing reloads it on
# a timer; crew-vmctl's nft-verify checks it.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

rules=/srv/crew/agent/current/etc/nft.conf
[ -f "$rules" ] || fail "the agent's release has no $rules"

ip link show crew0 >/dev/null 2>&1 || ip link add crew0 type dummy
ip addr replace 10.199.0.1/32 dev crew0
ip link set crew0 up
nft -f "$rules" || fail "nftables refused $rules"
