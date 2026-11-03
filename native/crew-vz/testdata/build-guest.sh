#!/bin/bash
# Builds the crew-vz integration-test guest: an arm64 kernel Image (6.18
# LTS, arm64 defconfig plus kernel.config, everything built in) and a tiny
# ext4 rootfs whose only program is guestinit (a static Go binary run as
# /init). Needs Docker; the kernel build is cached, so reruns are quick.
#
#   native/crew-vz/testdata/build-guest.sh [outdir]
#
# Output (default <repo>/tmp/crew-vz-guest): Image, rootfs.ext4, init.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
native="$(cd "$here/../.." && pwd)"
repo="$(cd "$native/.." && pwd)"
out="${1:-$repo/tmp/crew-vz-guest}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

KVER="${KVER:-6.18.60}"
IMAGE="${BUILD_IMAGE:-debian:trixie-slim}"
GO="${GO:-go}"

run() {
  docker run --rm --platform linux/arm64 \
    -e KVER="$KVER" \
    -v "$here:/src:ro" -v "$out:/out" -v crew-vz-kernel-build:/build \
    "$IMAGE" bash /src/build-in-container.sh "$1"
}

if [ ! -f "$out/Image" ] || [ "$here/kernel.config" -nt "$out/Image" ] || [ -n "${REBUILD_KERNEL:-}" ]; then
  echo "== kernel $KVER"
  run kernel
fi

echo "== guest init"
(cd "$native" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOFLAGS=-mod=vendor \
  $GO build -trimpath -ldflags='-s -w' -o "$out/init" ./crew-vz/testdata/guestinit)

echo "== rootfs"
run rootfs

ls -la "$out/Image" "$out/rootfs.ext4"
