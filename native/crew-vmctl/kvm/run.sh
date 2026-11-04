#!/bin/sh
# Runs the agent's :kvm suite (apps/crew_agent/test/crew_agent/firecracker_kvm_test.exs)
# on this Linux host: real Firecracker VMs through crew-vmctl, as a box runs them.
#
#   sudo CREW_REAL_IMAGE_DIR=<dir> native/crew-vmctl/kvm/run.sh [--keep] [--conformance]
#
# CREW_REAL_IMAGE_DIR holds the guest image: `Image` (arm64) or `kernel`, and
# `rootfs.ext4`. On /srv/crew's filesystem it's reflinked, not copied.
#
# --conformance runs the driver conformance suite (spec §11.6,
# apps/crew_agent/test/conformance/) instead of the :kvm suite, with
# crew_cache up on 10.199.0.1 (./cache.sh) for item 4. The image must have
# the conformance check (images/guest/conformance). These pass through:
# CREW_CONFORMANCE_TARGETS, CREW_CONFORMANCE_EGRESS, CREW_CONFORMANCE_KIND,
# CREW_CONFORMANCE_STARTS, and CREW_CONFORMANCE_ONLY (a test name, for
# `mix test --only test:<name>`).
#
# From a checkout of this repo, it:
#   1. checks the host: root, /dev/kvm, systemd, nft, iptables-nft, ip, and
#      /srv/crew an XFS that isn't a real box's (no agent/ or root/ but this script's);
#   2. downloads the pinned Firecracker for this arch (../firecracker.env) and
#      checks its SHA-256;
#   3. builds crew-vmctl (vendored, with no network);
#   4. lays out /srv/crew/root/<version>/{bin,etc} and root/current as a box has them,
#      checks the units in one boot transaction (systemd-analyze verify),
#      puts them in /run/systemd/system (runtime only, gone at reboot)
#      and starts crew-net and crew-vmctl.socket;
#   5. runs `mix test --only kvm` (or the conformance suite) as root, on the host's network;
#   6. checks nothing is left: crew-vm units, taps, vm_pairs elements, jails;
#   7. takes it all down again, unless --keep.
#
# Go and Elixir are the ones on PATH (`go`, `mix`) if both are there. If not
# (Flatcar has neither) it uses the pinned images below, through a dockerd of
# its own, started for the run as a transient unit with no iptables rules and
# no bridge, and stopped at the end. Its caches are in /var/lib/crew-kvm.
set -eu

GO_IMAGE=golang:1.25.14-bookworm@sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437
ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-ubuntu-noble-20260917@sha256:d6bafec523f681f19d430ac1e19884022576b19d93e57e0db013633c73385bd2

here=$(cd "$(dirname "$0")" && pwd)
vmctl_src=$(cd "$here/.." && pwd)
repo=$(cd "$here/../../.." && pwd)
data=/srv/crew
work=/var/lib/crew-kvm
marker=$data/.crew-kvm-test
units="crew-vmctl.socket crew-vmctl@.service crew-net.service crew-net-site4.service crew-net-site4.timer"
docker_sock=/run/crew-kvm-docker.sock
keep=0
conformance=0
for arg in "$@"; do
  case $arg in
    --keep) keep=1 ;;
    --conformance) conformance=1 ;;
    *) echo "kvm: unknown argument $arg" >&2 && exit 64 ;;
  esac
done

say() { echo "kvm: $*"; }
die() {
  echo "kvm: $*" >&2
  exit 1
}

# -- 1. the host --------------------------------------------------------------

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ -c /dev/kvm ] || die "there's no /dev/kvm"
[ -n "${CREW_REAL_IMAGE_DIR:-}" ] || die "set CREW_REAL_IMAGE_DIR to the guest image's directory"
image=$(cd "$CREW_REAL_IMAGE_DIR" && pwd)
[ -f "$image/rootfs.ext4" ] || die "$image has no rootfs.ext4"
[ -f "$image/Image" ] || [ -f "$image/kernel" ] || die "$image has no Image or kernel"
for t in systemctl systemd-run nft iptables-nft-restore iptables-nft ip curl sha256sum tar findmnt xfs_quota; do
  command -v "$t" >/dev/null || die "this host has no $t"
done
[ -d "$data" ] || die "$data doesn't exist (an XFS with reflink=1)"
[ "$(stat -f -c %T "$data")" = xfs ] || die "$data must be an XFS (with reflink=1)"
for d in agent root vmctl; do
  if [ -e "$data/$d" ] && [ ! -e "$marker" ]; then
    die "$data/$d exists and this script didn't make it: is this a Crew box? Not here."
  fi
done
case $image/ in
  "$data"/agent/* | "$data"/root/* | "$data"/vms/* | "$data"/images/* | "$data"/jail/*)
    die "keep the image out of $data/{agent,root,vms,images,jail}"
    ;;
esac
touch "$marker"
mkdir -p "$work"

case $(uname -m) in
  x86_64) goarch=amd64 ;;
  aarch64) goarch=arm64 ;;
  *) die "Firecracker runs on x86_64 and aarch64, not $(uname -m)" ;;
esac

native=0
command -v go >/dev/null && command -v mix >/dev/null && native=1

dock() { DOCKER_HOST=unix://$docker_sock docker "$@"; }

# shellcheck disable=SC2329 # the EXIT trap's
teardown() {
  status=$?
  [ "$conformance" = 0 ] || "$here/cache.sh" down --if-ours || true
  if [ "$keep" = 0 ]; then
    say "taking it down"
    systemctl stop crew-vmctl.socket crew-net-site4.timer crew-net.service 2>/dev/null || true
    for u in $units; do rm -f "/run/systemd/system/$u"; done
    systemctl daemon-reload
    nft delete table inet crew 2>/dev/null || true
    nft delete table ip mangle 2>/dev/null || true
    ip link del crew0 2>/dev/null || true
    # Taps a failed test left (a passing run leaves none: step 6 checks).
    for t in $(ip -o link show | sed -n 's/^[0-9]*: \(crewt[0-9]*\)[:@].*/\1/p'); do
      ip link del "$t" 2>/dev/null || true
    done
    rm -rf "$data/agent" "$data/root" "$data/vms" "$data/images" "$data/jail" "$data/vmctl" "$marker" /run/crew
  else
    say "--keep: leaving crew-net, crew-vmctl.socket and $data as they are"
  fi
  if [ "$native" = 0 ]; then
    systemctl stop crew-kvm-dockerd.service 2>/dev/null || true
  fi
  exit "$status"
}
trap teardown EXIT INT TERM

if [ "$native" = 0 ]; then
  command -v dockerd >/dev/null || die "needs go and mix on PATH, or dockerd for the pinned images"
  if ! systemctl is-active -q crew-kvm-dockerd.service; then
    say "starting a dockerd for the toolchains (no iptables, no bridge)"
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
fi

# -- 2. Firecracker ---------------------------------------------------------------

"$vmctl_src/fetch-firecracker.sh" "$work/firecracker" "$(uname -m)"

# -- 3. crew-vmctl ------------------------------------------------------------------

say "building crew-vmctl ($goarch)"
mkdir -p "$work/bin"
if [ "$native" = 1 ]; then
  (cd "$repo/native" && CGO_ENABLED=0 GOFLAGS=-mod=vendor GOPROXY=off \
    go build -trimpath -buildvcs=false -ldflags "-X main.version=kvm-test" \
    -o "$work/bin/crew-vmctl" ./crew-vmctl/cmd/crew-vmctl)
else
  dock run --rm --network none -v "$repo/native:/src:ro" -v "$work/bin:/out" -w /src \
    -e CGO_ENABLED=0 -e GOFLAGS=-mod=vendor -e GOPROXY=off -e GOCACHE=/tmp/go-cache \
    "$GO_IMAGE" go build -trimpath -buildvcs=false -ldflags "-X main.version=kvm-test" \
    -o /out/crew-vmctl ./crew-vmctl/cmd/crew-vmctl
fi

# -- 4. the box ---------------------------------------------------------------------

# What root runs goes in root/<version>, root's, with root/current its
# link, as the box's Ignition installs a release; agent/ is the agent's.
say "installing into $data/root/kvm-test and /run/systemd/system"
release=$data/root/kvm-test
install -d -m 0755 "$release/bin" "$release/etc/systemd" "$data/agent" "$data/vms" "$data/images" "$data/jail"

# §12.4's XFS project quotas, as a box's Ignition sets them
# (crew-quota.service): vms/ + jail/ are one project, agent/ + images/
# another. XFS refuses a hard link from one project to another (EXDEV),
# which a data disk without quotas never shows.
if ! findmnt -no OPTIONS "$data" | tr , '\n' | grep -qx 'prjquota\|pquota'; then
  dev=$(findmnt -no SOURCE "$data")
  say "remounting $data ($dev) with prjquota: XFS turns quotas on only at mount"
  umount "$data" || die "couldn't unmount $data to turn on project quotas"
  mount -o noatime,prjquota "$dev" "$data" || die "couldn't mount $dev on $data with prjquota"
fi
project() { # id dir
  xfs_quota -x -c "project -s -p $data/$2 $1" "$data" >/dev/null || die "couldn't put $data/$2 in project $1"
}
project 10 vms
project 10 jail
project 12 agent
project 12 images
say "project quotas: vms/ and jail/ in 10, agent/ and images/ in 12"
install -m 0755 "$work/firecracker/firecracker" "$work/firecracker/jailer" "$work/bin/crew-vmctl" "$release/bin/"
cp "$vmctl_src/etc/nft.conf" "$vmctl_src/etc/connlimit.rules" "$release/etc/"
cp "$vmctl_src/etc/systemd/"* "$release/etc/systemd/"
ln -sfn kvm-test "$data/root/current"
# The tests run as root, so the socket's group is root's here.
for u in $units; do
  sed 's/^SocketGroup=_crewagent$/SocketGroup=root/' "$vmctl_src/etc/systemd/$u" >"/run/systemd/system/$u"
done

# The units in one boot transaction, as multi-user.target and
# sockets.target pull them in together: systemd-analyze verify on each
# alone doesn't see an ordering cycle between them. Any output fails.
check=$(mktemp -d)
for u in $units; do cp "/run/systemd/system/$u" "$check/"; done
printf '[Unit]\nDescription=crew-vmctl kvm: the units at boot\nWants=%s\n' \
  "crew-net.service crew-vmctl.socket crew-net-site4.timer network-online.target sockets.target basic.target timers.target" \
  >"$check/crew-boot-check.target"
# shellcheck disable=SC2086 # $units is a list
verified=$(cd "$check" && systemd-analyze verify crew-boot-check.target $units 2>&1) || true
rm -rf "$check"
[ -z "$verified" ] || {
  echo "$verified"
  die "the units don't verify"
}
say "the units verify (systemd-analyze, one boot transaction)"
systemctl daemon-reload
systemctl restart crew-net.service
systemctl restart crew-vmctl.socket
ip -br addr show crew0

# -- 5. the tests ---------------------------------------------------------------------

paths=""
only=kvm
if [ "$conformance" = 1 ]; then
  # Item 4's cache, on 10.199.0.1 as a box's (crew0 is crew-net's now).
  "$here/cache.sh" up
  export CREW_CONFORMANCE_DRIVER=firecracker CREW_CONFORMANCE_CACHE_MGMT=http://127.0.0.1:7780
  CREW_CONFORMANCE_CACHE_TOKEN=$(cat "$work/cache.token")
  export CREW_CONFORMANCE_CACHE_TOKEN
  paths=test/conformance
  only=conformance
  # One argument: the name has spaces.
  [ -z "${CREW_CONFORMANCE_ONLY:-}" ] || only="test:test $CREW_CONFORMANCE_ONLY"
fi
pass_env="CREW_CONFORMANCE_DRIVER CREW_CONFORMANCE_CACHE_MGMT CREW_CONFORMANCE_CACHE_TOKEN
  CREW_CONFORMANCE_TARGETS CREW_CONFORMANCE_EGRESS CREW_CONFORMANCE_KIND CREW_CONFORMANCE_STARTS"

say "mix test $paths --only $only"
status=0
if [ "$native" = 1 ]; then
  # shellcheck disable=SC2086 # $paths is words
  (cd "$repo/apps/crew_agent" && export MIX_ENV=test CREW_REAL_IMAGE_DIR="$image" &&
    mix deps.get && mix test $paths --only "$only") || status=$?
else
  # The image, plus make and a compiler (muontrap compiles a C port) and
  # nft (a test changes the ruleset, as root on the host's network, so the
  # container has NET_ADMIN).
  tag=crew-kvm-elixir:2
  if ! dock image inspect "$tag" >/dev/null 2>&1; then
    printf 'FROM %s\nRUN apt-get update -qq && apt-get install -y -qq --no-install-recommends make gcc libc6-dev nftables >/dev/null && rm -rf /var/lib/apt/lists/*\n' \
      "$ELIXIR_IMAGE" | dock build --network host -q -t "$tag" -
  fi
  mkdir -p "$work/mix" "$work/hex"
  envs=""
  for v in $pass_env; do envs="$envs -e $v"; done
  # shellcheck disable=SC2086,SC2016 # $envs is words (-e NAME passes NAME through); $PATHS and $ONLY are the container's
  dock run --rm --network host --cgroupns host --cap-add NET_ADMIN --device /dev/kvm --device /dev/net/tun \
    -v "$data:$data" -v /run/crew:/run/crew -v "$image:$image:ro" -v "$repo:/src" \
    -v "$work/mix:/root/.mix" -v "$work/hex:/root/.hex" $envs \
    -e MIX_ENV=test -e CREW_REAL_IMAGE_DIR="$image" -e PATHS="$paths" -e ONLY="$only" -w /src/apps/crew_agent \
    "$tag" sh -c 'mix local.hex --force --if-missing >/dev/null &&
      mix local.rebar --force --if-missing >/dev/null && mix deps.get >/dev/null &&
      mix test $PATHS --only "$ONLY"' || status=$?
fi

# -- 6. nothing left ---------------------------------------------------------------------

left=$(systemctl list-units --all --plain --no-legend 'crew-vm-*' || true)
[ -z "$left" ] || { echo "$left"; status=1; say "crew-vm units are left"; }
if ip -br link | grep -q '^crewt'; then
  ip -br link | grep '^crewt'
  status=1
  say "taps are left"
fi
if nft -j list set inet crew vm_pairs | grep -q '"elem"'; then
  nft list set inet crew vm_pairs
  status=1
  say "vm_pairs isn't empty"
fi
if [ -n "$(ls -A "$data/jail/firecracker" 2>/dev/null)" ]; then
  ls -la "$data/jail/firecracker"
  status=1
  say "jails are left"
fi

if [ "$status" = 0 ]; then say "passed"; else say "FAILED"; fi
exit "$status"
