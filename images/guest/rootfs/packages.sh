#!/bin/bash
# Installs the guest image's packages (docs/crew_spec.md §13.1), in the
# rootfs Dockerfile's `packages` stage. /crew holds packages.txt,
# packages.lock and the scripts; the apt key fingerprints come as env.
#
# LOCK_MODE=check (the default): packages.lock drives resolution (every
# locked package is pinned at its version), and the build fails unless
# what's installed is exactly this arch's lines of the lock: no version
# different, nothing extra, nothing missing.
#
# LOCK_MODE=update: no pins; whatever the snapshot and packages.txt
# resolve to is written to /var/lib/crew-image/packages.resolved, which
# `make lock` copies into packages.lock.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${DOCKER_APT_KEY_FPR:?}" "${PGDG_APT_KEY_FPR:?}"
export DOCKER_APT_KEY_FPR PGDG_APT_KEY_FPR
lock=/crew/packages.lock
mode=${LOCK_MODE:-check}
arch=${CREW_ARCH:?}
case "$arch" in arm64) debarch=arm64 ;; x64) debarch=amd64 ;; *) exit 1 ;; esac
[ "$(dpkg --print-architecture)" = "$debarch" ] || { echo "packages: not a $debarch container" >&2; exit 1; }

snapshot=$(awk '$1 == "snapshot" { print $2 }' "$lock")
out=/var/lib/crew-image
mkdir -p "$out"

# Docker's base image deletes .debs after each install, which defeats the
# build's apt cache mount. The VM doesn't need it either.
rm -f /etc/apt/apt.conf.d/docker-clean

locked() { awk -v a="$arch" '$1 == a { print $2, $3 }' "$lock" | LC_ALL=C sort; }

case "$mode" in
check)
  if [ -z "$(locked)" ]; then
    echo "packages: packages.lock has nothing for $arch; run make lock ARCH=$arch" >&2
    exit 1
  fi
  locked | awk '{ printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n", $1, $2 }' \
    > /etc/apt/preferences.d/90crew-lock
  ;;
update) rm -f /etc/apt/preferences.d/90crew-lock ;;
*) echo "packages: LOCK_MODE must be check or update" >&2; exit 1 ;;
esac

# packages.txt, for this arch: comments and blanks dropped, [arch] honoured.
wanted=$(sed -e 's/#.*//' /crew/packages.txt | awk -v a="$arch" '
  NF == 0 { next }
  NF == 1 { print $1; next }
  $2 == "[" a "]" { print $1 }')

install() { apt-get install -qq --no-install-recommends --allow-downgrades "$@" >/dev/null; }

/crew/scripts/apt-sources.sh snapshot "$snapshot"
install curl gnupg
/crew/scripts/apt-sources.sh thirdparty
apt-get dist-upgrade -qq --allow-downgrades >/dev/null
# shellcheck disable=SC2086
install $wanted

dpkg-query -W -f '${db:Status-Abbrev}\t${Package}\t${Version}\n' |
  awk -F'\t' '$1 ~ /^ii/ { print $2, $3 }' | LC_ALL=C sort > "$out/packages.resolved"
echo "packages: $(wc -l < "$out/packages.resolved") installed"

if [ "$mode" = check ]; then
  if ! diff -u <(locked) "$out/packages.resolved" > "$out/packages.diff"; then
    echo "packages: what's installed differs from packages.lock ($arch); - locked, + installed:" >&2
    grep '^[-+][^-+]' "$out/packages.diff" >&2
    echo "packages: if that's intended, run make lock ARCH=$arch and review the diff" >&2
    exit 1
  fi
  echo "packages: exactly packages.lock ($arch)"
fi
rm -f /etc/apt/preferences.d/90crew-lock "$out/packages.diff"
