#!/bin/sh
# Smoke-tests a release tarball on the runner that built it, before
# anything is signed (docs/crew_spec.md §20.1 items 3 and 4): it holds
# what the box's install expects, it starts, every binary prints the
# release's version, and the driver's own binaries run.
#
#   packaging/release/smoke.sh crew-agent-1.2.3-linux-amd64.tar.gz 1.2.3 linux-amd64
#
# What the Linux agent must hold is what crew-agent-install refuses a
# release without (docs/architecture.md, "Flatcar box notes"). The
# darwin agent's layout is packaging/release/build-darwin.sh's; this
# checks its agent and crew-vz, and crew-vz's ad-hoc signature.
#
# A driver check that boots a VM is the conformance suite's (§11.6),
# not this: here Firecracker and the jailer only have to run, and
# /dev/kvm's presence is reported.
set -eu

tarball=${1:?usage: smoke.sh TARBALL VERSION TARGET}
version=${2:?version}
target=${3:?target}

name=$(basename "$tarball")
case $name in
  "crew-agent-$version-$target.tar.gz") component=agent ;;
  "crew-cache-$version-$target.tar.gz") component=cache ;;
  *) echo "smoke: $name isn't crew-<agent|cache>-$version-$target.tar.gz" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/root" "$work/tmp"
tar -xzf "$tarball" -C "$work/root"
cd "$work/root"

problems=0
problem() {
  echo "smoke: $name: $*" >&2
  problems=$((problems + 1))
}
need() {
  for f in "$@"; do
    case $f in
      */) [ -d "$f" ] && [ -n "$(ls -A "$f")" ] || problem "no ${f%/} (or it's empty)" ;;
      bin/*) [ -x "$f" ] || problem "no executable $f" ;;
      *) [ -f "$f" ] || problem "no $f" ;;
    esac
  done
}
# prints BIN ARG EXPECTED: BIN ARG prints EXPECTED as its first line.
prints() {
  [ -x "$1" ] || return 0
  got=$("$1" "$2" 2>&1 | head -n 1) || true
  [ "$got" = "$3" ] || problem "$1 $2 prints \"$got\", not \"$3\""
}
# starts BIN: the Elixir release boots far enough to run code.
starts() {
  [ -x "$1" ] || return 0
  got=$(RELEASE_TMP=$work/tmp CREW_DATA_DIR=$work/tmp "$1" eval 'IO.puts(:started)' 2>&1 | tail -n 1) || true
  [ "$got" = started ] || problem "$1 doesn't start: $got"
}

case $component-$target in
  agent-linux-*)
    need bin/crew_agent bin/crew-vmctl bin/firecracker bin/jailer etc/nft.conf etc/connlimit.rules etc/systemd/
    prints bin/crew_agent version "crew_agent $version"
    prints bin/crew-vmctl version "crew-vmctl $version"
    starts bin/crew_agent
    for bin in firecracker jailer; do
      if [ -x "bin/$bin" ] && ! "bin/$bin" --version > /dev/null 2>&1; then problem "bin/$bin --version fails"; fi
    done
    if [ -c /dev/kvm ]; then echo "smoke: /dev/kvm is here"; else echo "smoke: no /dev/kvm on this runner"; fi
    ;;
  agent-darwin-*)
    need bin/crew_agent bin/crew-vz
    prints bin/crew_agent version "crew_agent $version"
    prints bin/crew-vz version "crew-vz $version"
    starts bin/crew_agent
    if [ "$(uname)" = Darwin ] && [ -x bin/crew-vz ]; then
      codesign --verify --strict bin/crew-vz || problem "bin/crew-vz isn't validly signed"
      codesign -d --entitlements - bin/crew-vz 2>/dev/null | grep -q com.apple.security.virtualization ||
        problem "bin/crew-vz lacks the virtualization entitlement"
    fi
    if [ -x bin/vfkit ] && ! bin/vfkit --version > /dev/null 2>&1; then problem "bin/vfkit --version fails"; fi
    ;;
  cache-linux-*)
    need bin/crew_cache
    prints bin/crew_cache version "crew_cache $version"
    starts bin/crew_cache
    ;;
  *)
    problem "nothing to check for $component on $target"
    ;;
esac

[ "$problems" -eq 0 ] || exit 1
echo "smoke: $name: ok"
