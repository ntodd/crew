# The mac-vz box's cache VM (docs/crew_spec.md §15.6), every boot, as
# root, before crew-cache: crew_cache listens on 10.199.0.1 (crew0), as
# on any box, management included. The Mac reaches it on this VM's own
# address: crew-vz forwards each job VM's 10.199.0.1:{53,80,443} there,
# and the agent manages the cache on :7780 with its token. The Mac is the
# vmnet gateway, the only source let in; nothing else on the Mac's
# network (its other VMs) gets anything from this VM.
#
# Also sizes the store: this VM is the cache's alone, so 80% of the data
# disk rather than a box's 25%.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

if [ ! -e /sys/class/net/crew0 ]; then ip link add crew0 type dummy; fi
ip addr replace 10.199.0.1/32 dev crew0
ip link set dev crew0 up

# The default route's interface, address and gateway (the Mac).
i=0
while :; do
  route=$(ip -4 route show default | head -n 1)
  dev=$(printf '%s\n' "$route" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  gw=$(printf '%s\n' "$route" | sed -n 's/^default via \([0-9.]*\) .*/\1/p')
  if [ -n "$dev" ] && [ -n "$gw" ]; then
    addr=$(ip -4 -o addr show dev "$dev" | awk '{ split($4, a, "/"); print a[1]; exit }')
    if [ -n "$addr" ]; then break; fi
  fi
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "no default route after 60 s"
  sleep 1
done

nft -f - <<EOF
table inet crew_cachevm
delete table inet crew_cachevm
table inet crew_cachevm {
  chain pre {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$dev" ip saddr $gw ip daddr $addr tcp dport { 53, 80, 443, 7780 } dnat ip to 10.199.0.1
    iifname "$dev" ip saddr $gw ip daddr $addr udp dport 53 dnat ip to 10.199.0.1
  }
  chain in {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ip saddr $gw accept
    meta l4proto { icmp, ipv6-icmp } accept
    udp sport 67 udp dport 68 accept
  }
}
EOF

mkdir -p /run/crew-box
total=$(df -Pk "$data" | awk 'NR == 2 { print $2 }')
echo "CREW_CACHE_MAX_GIB=$((total * 8 / 10 / 1048576))" > /run/crew-box/cache.env
say "serving the cache on $addr to $gw"
