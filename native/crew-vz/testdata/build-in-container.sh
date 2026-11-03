#!/bin/bash
# Runs inside a linux/arm64 Debian container (see build-guest.sh).
#   /src    this directory (read-only)
#   /out    output: Image, rootfs.ext4
#   /build  a named Docker volume caching the kernel tree (bind mounts from
#           macOS break tar and are slow to build on)
set -euo pipefail

KVER="${KVER:?}"
step="${1:?kernel|rootfs}"

apt_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

case "$step" in
kernel)
  apt_deps build-essential flex bison bc libelf-dev libssl-dev xz-utils curl ca-certificates cpio kmod python3
  mkdir -p /build
  cd /build
  if [ ! -d "linux-$KVER" ]; then
    curl -fsSL -o "linux-$KVER.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz"
    tar -xf "linux-$KVER.tar.xz"
    rm "linux-$KVER.tar.xz"
  fi
  cd "linux-$KVER"
  make -s ARCH=arm64 defconfig
  scripts/kconfig/merge_config.sh -m .config /src/kernel.config >/dev/null
  make -s ARCH=arm64 olddefconfig
  # Fail loudly if a symbol we need didn't survive olddefconfig.
  missing=0
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=y)
        if ! grep -qx "$line" .config; then echo "missing: $line" >&2; missing=1; fi ;;
    esac
  done < /src/kernel.config
  [ "$missing" = 0 ]
  make -s ARCH=arm64 -j"$(nproc)" Image
  cp arch/arm64/boot/Image /out/Image
  echo "kernel: $(du -h /out/Image | cut -f1)"
  ;;
rootfs)
  apt_deps e2fsprogs
  root=$(mktemp -d)
  mkdir -p "$root"/{dev,proc,sys,tmp,etc,sbin,mnt}
  install -m 0755 /out/init "$root/init"
  ln -s /init "$root/sbin/init"
  mknod -m 0600 "$root/dev/console" c 5 1
  mknod -m 0666 "$root/dev/null" c 1 3
  echo "nameserver 10.199.0.1" > "$root/etc/resolv.conf"
  echo "127.0.0.1 localhost" > "$root/etc/hosts"
  rm -f /out/rootfs.ext4
  mkfs.ext4 -q -F -L crewtest -d "$root" /out/rootfs.ext4 256M
  echo "rootfs: $(du -h /out/rootfs.ext4 | cut -f1) (sparse)"
  ;;
esac
