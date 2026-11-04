#!/bin/sh
# crew_cache on this Linux host for the driver conformance suite (spec
# §11.6 item 4), as a box runs it: the registry, /healthz and DNS on
# 10.199.0.1 (crew0), management on 127.0.0.1:7780 with a token.
#
#   sudo native/crew-vmctl/kvm/cache.sh up [--vmnet]
#   sudo native/crew-vmctl/kvm/cache.sh down [--if-ours]
#
# It runs from this checkout's apps/crew_cache with MIX_ENV=prod (so
# CrewCache.Env reads the same variables a release does) in the pinned
# Elixir image, on the host's network, through a private dockerd with no
# iptables rules or bridge (crew-kvm-dockerd, as run.sh starts it). The
# store is /var/lib/crew-kvm/cache; the token is in /var/lib/crew-kvm/cache.token.
#
# --vmnet also serves 10.199.0.1:{53,80,443} on this host's address to
# the vmnet host (192.168.64.1) only, by DNAT: this host then stands in
# for a mac-vz box's cache VM (§15.6) for the vz suite on the Mac
# (CREW_CONFORMANCE_CACHE_ADDR=<this host>, management through an SSH
# tunnel). `down` takes all of it away.
set -eu

ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-ubuntu-noble-20260917@sha256:d6bafec523f681f19d430ac1e19884022576b19d93e57e0db013633c73385bd2

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=/var/lib/crew-kvm
docker_sock=/run/crew-kvm-docker.sock
name=crew-conformance-cache
vmnet_host=192.168.64.1

say() { echo "cache: $*"; }
die() {
  echo "cache: $*" >&2
  exit 1
}
dock() { DOCKER_HOST=unix://$docker_sock docker "$@"; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"

dockerd_up() {
  if ! systemctl is-active -q crew-kvm-dockerd.service; then
    say "starting a dockerd (no iptables, no bridge)"
    systemd-run --quiet --unit=crew-kvm-dockerd --collect -p KillMode=mixed \
      /usr/bin/env dockerd --iptables=false --ip6tables=false --bridge=none \
      --data-root="$work/docker" --exec-root=/run/crew-kvm-docker \
      --pidfile=/run/crew-kvm-docker.pid -H "unix://$docker_sock"
  fi
  i=0
  until dock info >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "the private dockerd didn't come up"
    sleep 0.5
  done
}

up() {
  mkdir -p "$work/cache" "$work/mix" "$work/hex"
  if [ ! -e /sys/class/net/crew0 ]; then
    ip link add crew0 type dummy
    touch "$work/cache.crew0"
  fi
  ip addr replace 10.199.0.1/32 dev crew0
  ip link set dev crew0 up
  [ -s "$work/cache.token" ] || { umask 077 && head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$work/cache.token"; }
  token=$(cat "$work/cache.token")
  dockerd_up
  if curl -fsS -H "authorization: Bearer $token" http://127.0.0.1:7780/stats >/dev/null 2>&1; then
    say "crew_cache is already up"
    vmnet "${1:-}"
    return 0
  fi
  touch "$work/cache.ours"
  dock rm -f "$name" >/dev/null 2>&1 || true
  say "starting crew_cache on 10.199.0.1 (management 127.0.0.1:7780)"
  dock run -d --name "$name" --network host \
    -v "$repo/apps/crew_cache:/src/crew_cache:ro" -v "$repo/apps/crew_protocol:/src/crew_protocol:ro" \
    -v "$work/cache:/data" -v "$work/mix:/root/.mix" -v "$work/hex:/root/.hex" \
    -e MIX_ENV=prod -e CREW_CACHE_DIR=/data -e CREW_CACHE_LISTEN=10.199.0.1 \
    -e CREW_CACHE_MGMT_LISTEN=127.0.0.1:7780 -e CREW_CACHE_MGMT_TOKEN="$token" -e CREW_CACHE_MAX_GIB=20 \
    "$ELIXIR_IMAGE" bash -c '
      set -e
      mkdir -p /w && cp -r /src/crew_cache /src/crew_protocol /w/ && rm -rf /w/*/_build /w/*/deps
      cd /w/crew_cache && mix local.hex --force --if-missing >/dev/null && mix local.rebar --force --if-missing >/dev/null
      mix deps.get >/dev/null && mix compile >/dev/null && exec mix run --no-halt' >/dev/null
  i=0
  until curl -fsS -H "authorization: Bearer $token" http://127.0.0.1:7780/stats >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || { dock logs "$name" | tail -30; die "crew_cache didn't come up"; }
    sleep 2
  done
  say "crew_cache is up: $(curl -fsS http://10.199.0.1/healthz)"
  vmnet "${1:-}"
}

vmnet() {
  if [ "${1:-}" = --vmnet ]; then
    addr=$(ip -4 -o addr show dev eth0 | awk '{ split($4, a, "/"); print a[1]; exit }')
    nft -f - <<EOF
table ip crew_conformance
delete table ip crew_conformance
table ip crew_conformance {
  chain pre {
    type nat hook prerouting priority dstnat;
    iifname "eth0" ip saddr $vmnet_host ip daddr $addr tcp dport { 53, 80, 443 } dnat to 10.199.0.1
    iifname "eth0" ip saddr $vmnet_host ip daddr $addr udp dport 53 dnat to 10.199.0.1
  }
}
EOF
    say "serving $vmnet_host on $addr:{53,80,443} (CREW_CONFORMANCE_CACHE_ADDR=$addr)"
  fi
}

down() {
  # --if-ours: only a cache this run started (run.sh's teardown), not
  # one already serving another run.
  if [ "${1:-}" = --if-ours ] && [ ! -e "$work/cache.ours" ]; then return 0; fi
  rm -f "$work/cache.ours"
  nft delete table ip crew_conformance 2>/dev/null || true
  if systemctl is-active -q crew-kvm-dockerd.service; then dock rm -f "$name" >/dev/null 2>&1 || true; fi
  if [ -e "$work/cache.crew0" ]; then
    ip link del crew0 2>/dev/null || true
    rm -f "$work/cache.crew0"
  fi
  say "down"
}

case ${1:-} in
  up) shift && up "$@" ;;
  down) shift && down "$@" ;;
  *) die "usage: cache.sh up [--vmnet] | down [--if-ours]" ;;
esac
