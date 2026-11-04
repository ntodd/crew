#!/bin/bash
# Downloads the kernel tarball and verifies it (docs/crew_spec.md §13.1):
#   - its SHA-256 must be KERNEL_SHA256;
#   - its .sign (a signature over the uncompressed .tar) must be good and
#     made by a key in KERNEL_SIGNERS. Only the keys in kernel/keys/ are
#     trusted, and each must carry the fingerprint its file is named for.
#
#   fetch.sh <dir>
#
# Leaves <dir>/linux-<version>.tar.xz, verified. A tarball already there is
# verified again rather than trusted. Needs curl, gpg, gpgv, xz and
# sha256sum (or shasum).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir=${1:?usage: fetch.sh <dir>}
# shellcheck source=../versions.env
[ -n "${KERNEL_VERSION:-}" ] || . "$here/../versions.env"
: "${KERNEL_VERSION:?}" "${KERNEL_SHA256:?}" "${KERNEL_SIGNERS:?}"

major=${KERNEL_VERSION%%.*}
base="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${KERNEL_VERSION}"
tarball="$dir/linux-${KERNEL_VERSION}.tar.xz"
sign="$dir/linux-${KERNEL_VERSION}.tar.sign"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$dir"
if [ ! -f "$tarball" ] || [ "$(sha256 "$tarball")" != "$KERNEL_SHA256" ]; then
  echo "fetch: downloading linux-${KERNEL_VERSION}.tar.xz"
  curl -fsSL --retry 5 --retry-all-errors -o "$tarball.part" "$base.tar.xz"
  mv "$tarball.part" "$tarball"
fi
curl -fsSL --retry 5 --retry-all-errors -o "$sign" "$base.tar.sign"

got=$(sha256 "$tarball")
if [ "$got" != "$KERNEL_SHA256" ]; then
  echo "fetch: linux-${KERNEL_VERSION}.tar.xz has SHA-256 $got, want $KERNEL_SHA256" >&2
  exit 1
fi

# A keyring of exactly the pinned keys.
gnupg=$(mktemp -d)
trap 'rm -rf "$gnupg"' EXIT
export GNUPGHOME="$gnupg"
IFS=, read -r -a signers <<<"$KERNEL_SIGNERS"
for fpr in "${signers[@]}"; do
  key="$here/keys/$fpr.asc"
  [ -f "$key" ] || { echo "fetch: no key file for $fpr in kernel/keys/" >&2; exit 1; }
  primary=$(gpg --batch --show-keys --with-colons "$key" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
  if [ "$primary" != "$fpr" ]; then
    echo "fetch: kernel/keys/$fpr.asc holds [$primary], not $fpr" >&2
    exit 1
  fi
  gpg --batch --quiet --import "$key" 2>/dev/null
done
gpg --batch --export "${signers[@]}" > "$gnupg/pinned.gpg"

# gpgv checks the signature against the pinned keyring only; the status
# line names the key that made it.
status=$(xz -cd "$tarball" | gpgv --keyring "$gnupg/pinned.gpg" --status-fd 1 "$sign" - 2>/dev/null) || {
  echo "fetch: linux-${KERNEL_VERSION}.tar.sign does not verify with the pinned keys" >&2
  exit 1
}
signer=$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status")
case ",$KERNEL_SIGNERS," in
  *",$signer,"*) ;;
  *) echo "fetch: signed by $signer, which isn't in KERNEL_SIGNERS" >&2; exit 1 ;;
esac
echo "fetch: linux-${KERNEL_VERSION}.tar.xz sha256 $got, signed by $signer"
