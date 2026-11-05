#!/bin/bash
# The guest kernel's CI checks (docs/crew_spec.md §13.1), on a full config:
#
#   1. moby's contrib/check-config.sh (pinned by commit and SHA-256) must
#      report no "Generally Necessary" CONFIG_ item missing;
#   2. the Crew list must be built in (=y): there's no initrd, and nothing
#      at boot should wait on a module;
#   3. CONFIG_VIRTIO_BALLOON must be off.
#
#   check.sh <config> <arch>
#
# check-config.sh also reports on the machine it runs on (the cgroup
# mount, AppArmor, sysctls); those lines say nothing about the config and
# are ignored. Its kernel-version checks read `uname -r`, so it runs with a
# `uname` that answers the config's own version.
#
# Runs on Linux or macOS (bash, curl, grep). Downloads go to
# CREW_GUEST_CACHE (default <repo>/tmp/guest-cache).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
config=${1:?usage: check.sh <config> <arch>}
arch=${2:?usage: check.sh <config> <arch>}
# shellcheck source=../versions.env
. "$here/../versions.env"
cache=${CREW_GUEST_CACHE:-$here/../../../tmp/guest-cache}

crew_common="IP_PNP VIRTIO_MMIO VIRTIO_PCI VIRTIO_BLK VIRTIO_NET HW_RANDOM_VIRTIO NFT_COMPAT
  NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK IP_NF_NAT IP_NF_FILTER
  IP_NF_TARGET_MASQUERADE BPF_SYSCALL CGROUP_BPF USER_NS SECCOMP_FILTER BINFMT_MISC FUSE_FS
  TUN VXLAN OVERLAY_FS BRIDGE VETH EXT4_FS"
case "$arch" in
  # The power button: VZ's requestStop and Firecracker arm64's both arrive
  # through gpio-keys on a PL061.
  arm64) crew_arch="INPUT_EVDEV KEYBOARD_GPIO GPIO_PL061" ;;
  x64) crew_arch="SERIO_I8042 KEYBOARD_ATKBD" ;;
  *) echo "check: unknown arch $arch" >&2; exit 1 ;;
esac

[ -f "$config" ] || { echo "check: no config at $config" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fail=0

# The config must be for the pinned kernel and this arch.
# The header names ARCH as the build passed it (x86_64, not SRCARCH x86).
case "$arch" in arm64) karch=arm64 ;; x64) karch=x86_64 ;; esac
header=$(sed -n 's/^# Linux\/\([^ ]*\) \([^ ]*\) Kernel Configuration$/\1 \2/p' "$config" | head -1)
if [ "$header" != "$karch $KERNEL_VERSION" ]; then
  echo "check: $config is for '${header:-unknown}', want '$karch $KERNEL_VERSION'"
  fail=1
fi

# 1. moby's check-config.sh
script="$cache/check-config-$MOBY_CHECK_CONFIG_COMMIT.sh"
if [ ! -f "$script" ] || [ "$(sha256 "$script")" != "$MOBY_CHECK_CONFIG_SHA256" ]; then
  mkdir -p "$cache"
  curl -fsSL --retry 5 --retry-all-errors -o "$script.part" \
    "https://raw.githubusercontent.com/moby/moby/$MOBY_CHECK_CONFIG_COMMIT/contrib/check-config.sh"
  mv "$script.part" "$script"
fi
got=$(sha256 "$script")
if [ "$got" != "$MOBY_CHECK_CONFIG_SHA256" ]; then
  echo "check: check-config.sh at $MOBY_CHECK_CONFIG_COMMIT has SHA-256 $got, want $MOBY_CHECK_CONFIG_SHA256" >&2
  exit 1
fi

release=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$config")
shim=$(mktemp -d)
trap 'rm -rf "$shim"' EXIT
cat > "$shim/uname" <<EOF
#!/bin/sh
if [ "\$1" = -r ]; then echo "$KERNEL_VERSION$release"; else exec /usr/bin/uname "\$@"; fi
EOF
chmod +x "$shim/uname"

report=$(PATH="$shim:$PATH" NO_COLOR=1 sh "$script" "$config" 2>&1 || true)
necessary=$(awk '/^Generally Necessary:/ { on = 1; next } /^Optional Features:/ { on = 0 } on' <<<"$report")
# check-config.sh runs under `set -e` and stops at the first tool that
# fails (BSD sed, for one): a report without its later sections is no
# report.
if ! grep -q '^Optional Features:' <<<"$report" || ! grep -qE '^- CONFIG_' <<<"$necessary"; then
  echo "check: check-config.sh didn't run to the end (it needs GNU sed and grep):"
  echo "$report"
  exit 1
fi
missing=$(grep -E '^- CONFIG_[A-Z0-9_]+: missing' <<<"$necessary" || true)
if [ -n "$missing" ]; then
  echo "check: check-config.sh reports Generally Necessary items missing:"
  echo "$missing"
  fail=1
fi
echo "check: check-config.sh ($MOBY_CHECK_CONFIG_COMMIT): $(grep -cE '^- CONFIG_' <<<"$necessary") Generally Necessary items, $(grep -cE '^- CONFIG_[A-Z0-9_]+: missing' <<<"$necessary" || true) missing"

# 2. The Crew list, built in.
for opt in $crew_common $crew_arch; do
  if ! grep -qx "CONFIG_$opt=y" "$config"; then
    val=$(sed -n "s/^CONFIG_$opt=//p" "$config")
    echo "check: CONFIG_$opt must be =y, is ${val:-unset}"
    fail=1
  fi
done

# 3. No balloon.
if grep -q '^CONFIG_VIRTIO_BALLOON=' "$config"; then
  echo "check: CONFIG_VIRTIO_BALLOON must be off"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "check: $config ok ($arch, $KERNEL_VERSION$release)"
fi
exit $fail
