#!/bin/bash
# Tests for check.sh: the committed config passes, and each kind of breakage
# fails it. Linux only (check-config.sh needs GNU tools); on macOS run it
# through the builder: `make -C images/guest kernel-check-test`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
arch=${1:-arm64}
good="$here/$arch.config"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

expect() {
  local want=$1 name=$2 cfg=$3 pattern=${4:-} out status
  out=$("$here/check.sh" "$cfg" "$arch" 2>&1)
  status=$?
  if [ "$want" = pass ] && [ $status -ne 0 ]; then
    echo "FAIL $name: check.sh failed:"; echo "$out"; failures=$((failures + 1)); return
  fi
  if [ "$want" = fail ] && [ $status -eq 0 ]; then
    echo "FAIL $name: check.sh passed"; failures=$((failures + 1)); return
  fi
  if [ -n "$pattern" ] && ! grep -q -- "$pattern" <<<"$out"; then
    echo "FAIL $name: output lacks '$pattern':"; echo "$out"; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

# Writes a copy of the good config with sed expression $2 applied.
variant() {
  sed "$2" "$good" > "$tmp/$1.config"
  echo "$tmp/$1.config"
}

expect pass "the committed $arch.config" "$good"
expect fail "a Generally Necessary item missing (moby)" \
  "$(variant posix_mqueue 's/^CONFIG_POSIX_MQUEUE=y$/# CONFIG_POSIX_MQUEUE is not set/')" \
  "CONFIG_POSIX_MQUEUE: missing"
expect fail "a Crew item as a module" \
  "$(variant veth 's/^CONFIG_VETH=y$/CONFIG_VETH=m/')" "CONFIG_VETH must be =y, is m"
expect fail "a Crew item unset" \
  "$(variant tun 's/^CONFIG_TUN=y$/# CONFIG_TUN is not set/')" "CONFIG_TUN must be =y, is unset"
if [ "$arch" = arm64 ]; then
  expect fail "no power button" \
    "$(variant gpio 's/^CONFIG_KEYBOARD_GPIO=y$/# CONFIG_KEYBOARD_GPIO is not set/')" \
    "CONFIG_KEYBOARD_GPIO must be =y"
fi
expect fail "the balloon on" \
  "$(variant balloon 's/^# CONFIG_VIRTIO_BALLOON is not set$/CONFIG_VIRTIO_BALLOON=y/')" \
  "CONFIG_VIRTIO_BALLOON must be off"
expect fail "another kernel version" \
  "$(variant version 's/^# Linux\/\([^ ]*\) [^ ]* Kernel Configuration$/# Linux\/\1 6.1.1 Kernel Configuration/')" \
  "want '"

[ $failures -eq 0 ] && echo "check_test: all passed" || echo "check_test: $failures failed"
exit $((failures > 0))
