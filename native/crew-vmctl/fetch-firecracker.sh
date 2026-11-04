#!/bin/sh
# Downloads the pinned Firecracker release (firecracker.env) for an arch,
# checks the tarball's SHA-256 and puts firecracker and jailer in DIR.
#
#   native/crew-vmctl/fetch-firecracker.sh DIR [x86_64|aarch64]
#
# The arch defaults to this machine's. Needs curl, sha256sum and tar.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=firecracker.env
. "$here/firecracker.env"

dir=${1:?usage: fetch-firecracker.sh DIR [x86_64|aarch64]}
arch=${2:-$(uname -m)}
case $arch in
  x86_64 | amd64) arch=x86_64 sha=$FIRECRACKER_SHA256_X86_64 ;;
  aarch64 | arm64) arch=aarch64 sha=$FIRECRACKER_SHA256_AARCH64 ;;
  *) echo "fetch-firecracker: no Firecracker build for $arch" >&2; exit 1 ;;
esac

v=$FIRECRACKER_VERSION
name=firecracker-v$v-$arch.tgz
url=https://github.com/firecracker-microvm/firecracker/releases/download/v$v/$name

mkdir -p "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -x "$dir/firecracker" ] && "$dir/firecracker" --version 2>/dev/null | grep -q "v$v\$"; then
  echo "fetch-firecracker: $dir already has Firecracker v$v"
  exit 0
fi

curl -fsSL --retry 3 -o "$tmp/$name" "$url"
echo "$sha  $tmp/$name" | sha256sum -c - >/dev/null || {
  echo "fetch-firecracker: $name doesn't match its pinned SHA-256" >&2
  exit 1
}
tar -xzf "$tmp/$name" -C "$tmp"
install -m 0755 "$tmp/release-v$v-$arch/firecracker-v$v-$arch" "$dir/firecracker"
install -m 0755 "$tmp/release-v$v-$arch/jailer-v$v-$arch" "$dir/jailer"
echo "fetch-firecracker: Firecracker v$v ($arch) in $dir"
