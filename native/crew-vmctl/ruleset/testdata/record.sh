#!/bin/sh
# Records the listings crew-vmctl's ruleset tests compare: etc/ loaded the
# way crew-net loads it (UPLINK=eth0), as this host's nft and iptables-nft
# print it. Run as root in a throwaway network namespace, on a host with
# nftables and iptables-nft (a Debian container with NET_ADMIN will do):
#
#   sudo unshare --net sh native/crew-vmctl/ruleset/testdata/record.sh
#
# It writes nft-<version>-{clean,busy}.json and iptables-<version>-mangle.save
# here ("busy" has a vm_pairs and a site4 element, as a box with a VM does),
# and rules.sha256, the hash of the files they were recorded from.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
etc=$(cd "$here/../../etc" && pwd)

[ -z "$(nft list tables)" ] || {
  echo "record.sh: run it in a fresh network namespace (unshare --net)" >&2
  exit 1
}

nft_v=$(nft --version | sed -n 's/^nftables v\([0-9.]*\).*/\1/p')
ipt_v=$(iptables-nft --version | sed -n 's/^iptables v\([0-9.]*\).*/\1/p')

{ echo 'define UPLINK = "eth0"'; cat "$etc/nft.conf"; } | nft -f -
iptables-nft-restore <"$etc/connlimit.rules"

pretty() { python3 -m json.tool 2>/dev/null || cat; }
nft -j list table inet crew | pretty >"$here/nft-$nft_v-clean.json"
iptables-nft-save -t mangle >"$here/iptables-$ipt_v-mangle.save"
nft add element inet crew vm_pairs '{ crewt3 . 10.200.0.14 }'
nft add element inet crew site4 '{ 192.168.1.0/24 }'
nft -j list table inet crew | pretty >"$here/nft-$nft_v-busy.json"

cat "$etc/nft.conf" "$etc/connlimit.rules" | sha256sum | cut -d' ' -f1 >"$here/rules.sha256"
echo "record.sh: nft $nft_v, iptables $ipt_v"
