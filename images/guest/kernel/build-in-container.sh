#!/bin/bash
# The guest kernel's build (docs/crew_spec.md §13.1), inside the builder
# image (builder/Dockerfile). images/guest/build.sh runs it with:
#   /guest   images/guest (read-only, except for `config`)
#   /build   a Docker volume: downloads, the source tree and object trees
#            (macOS bind mounts break tar and are slow to build on)
#   /out     where `build` writes Image (or vmlinux), modules.tar, config
#
#   build-in-container.sh config   write kernel/<arch>.config from the
#                                  pinned defconfig plus <arch>.fragment
#   build-in-container.sh build    build from kernel/<arch>.config
#
# Env: CREW_ARCH (arm64 | x64), KBUILD_BUILD_TIMESTAMP, and versions.env.
set -euo pipefail

step=${1:?config|build}
# shellcheck source=../versions.env
. /guest/versions.env
arch=${CREW_ARCH:?}

case "$arch" in
  arm64) karch=arm64 target=Image image=arch/arm64/boot/Image ;;
  x64) karch=x86_64 target=vmlinux image=vmlinux ;;
  *) echo "kernel: unknown arch $arch" >&2; exit 1 ;;
esac

fragment=/guest/kernel/$arch.fragment
config=/guest/kernel/$arch.config
src=/build/src/linux-$KERNEL_VERSION
obj=/build/obj/$arch-$KERNEL_VERSION

export KBUILD_BUILD_USER=crew KBUILD_BUILD_HOST=crew
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-@0}
kmake() { make -s -C "$src" O="$obj" ARCH="$karch" "$@"; }

# The source tree is extracted only from a tarball fetch.sh has just
# verified; a stamp records which.
/guest/kernel/fetch.sh /build/dl
if [ "$(cat "$src/.crew-verified" 2>/dev/null)" != "$KERNEL_SHA256" ]; then
  rm -rf "$src"
  mkdir -p /build/src
  tar -C /build/src -xf "/build/dl/linux-$KERNEL_VERSION.tar.xz"
  echo "$KERNEL_SHA256" > "$src/.crew-verified"
fi
mkdir -p "$obj"

# Fails if a line of the fragment didn't survive into the config.
check_fragment() {
  local cfg=$1 missing=0 line key
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=n)
        key=${line%%=*}
        if grep -q "^$key=" "$cfg"; then echo "kernel: $key is set, want off" >&2; missing=1; fi ;;
      CONFIG_*=*)
        if ! grep -qxF "$line" "$cfg"; then
          echo "kernel: want $line, got $(grep "^${line%%=*}=" "$cfg" || echo "${line%%=*} unset")" >&2
          missing=1
        fi ;;
    esac
  done < "$fragment"
  return $missing
}

case "$step" in
config)
  rm -f "$obj/.config"
  kmake defconfig
  "$src/scripts/kconfig/merge_config.sh" -m -O "$obj" "$obj/.config" "$fragment" >/dev/null
  kmake olddefconfig
  check_fragment "$obj/.config"
  cp "$obj/.config" "$config"
  echo "kernel: wrote kernel/$arch.config"
  ;;
build)
  [ -f "$config" ] || { echo "kernel: no kernel/$arch.config (make kernel-config)" >&2; exit 1; }
  cp "$config" "$obj/.config"
  kmake olddefconfig
  # The committed config must already be what olddefconfig makes of it:
  # anything else means it was edited by hand or is for another version.
  if ! diff -u "$config" "$obj/.config" >&2; then
    echo "kernel: kernel/$arch.config isn't olddefconfig-clean for $KERNEL_VERSION; run make kernel-config" >&2
    exit 1
  fi
  check_fragment "$obj/.config"
  kmake -j"$(nproc)" "$target" modules
  release=$(kmake -s kernelrelease)
  mods=$(mktemp -d)
  kmake INSTALL_MOD_PATH="$mods" INSTALL_MOD_STRIP=1 modules_install
  # The build and source links point into this container.
  rm -f "$mods/lib/modules/$release/build" "$mods/lib/modules/$release/source"
  # modules/<release>/..., to be unpacked in /usr/lib (Ubuntu's /lib is a
  # symlink to it).
  mtime=${KBUILD_BUILD_TIMESTAMP#@}
  tar -C "$mods/lib" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" \
    -cf /out/modules.tar modules
  cp "$obj/$image" "/out/$(basename "$image")"
  cp "$obj/.config" /out/config
  echo "$release" > /out/release
  echo "kernel: $release, $(du -h "/out/$(basename "$image")" | cut -f1), modules $(du -h /out/modules.tar | cut -f1)"
  ;;
*)
  echo "kernel: unknown step $step" >&2
  exit 1
  ;;
esac
