#!/bin/bash
# Signs a release (docs/crew_spec.md §13.1, §20.1 item 6) with openssl and
# nothing else, for the release workflow's sign job, which runs no
# third-party actions. It makes exactly the signatures CrewProtocol.Auth
# makes (ed25519 is deterministic), and a test holds it to them:
#
#   <name>.manifest.json   a guest image manifest: <name>.manifest.sig, over
#                          "crew-manifest-v1\n" and the manifest's exact
#                          bytes (`mix crew_image.sign` in Elixir)
#   crew-<agent|cache>-<version>-<target>.tar.gz
#                          an agent or cache tarball: <file>.sha256 as
#                          sha256sum writes it, and <file>.sig over
#                          "crew-release-v1\n<version>\n<target>\n<sha256>"
#                          (`mix crew.sign` in Elixir)
#
# Signatures are base64 with no newline.
#
#   sign.sh [--release] [--key-file F] [--public-key-file P] FILE...
#
# The key is the base64 32-byte ed25519 seed, from CREW_RELEASE_SIGNING_KEY
# or --key-file (which may have # comments). --release refuses the
# development test key (keys/test-signing.key). --public-key-file refuses
# a key whose public half isn't the one in P (the release workflow passes
# packaging/release/release-key.pub), before anything is signed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
usage="usage: sign.sh [--release] [--key-file F] [--public-key-file P] FILE..."
release=0 key_file="" public_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) release=1; shift ;;
    --key-file) key_file=${2:?$usage}; shift 2 ;;
    --public-key-file) public_file=${2:?$usage}; shift 2 ;;
    --) shift; break ;;
    -*) echo "sign: unknown option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "$usage" >&2; exit 1; }

# What each file is, before the key is touched: a manifest, or a tarball
# named as CrewImage.Release names them.
tarball_re='^crew-(agent|cache)-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)-(linux-amd64|linux-arm64|darwin-arm64)\.tar\.gz$'
for f in "$@"; do
  base=$(basename -- "$f")
  case "$base" in
    *[!A-Za-z0-9._-]*) echo "sign: $f: not a name sign.sh signs" >&2; exit 1 ;;
    *.manifest.json) ;;
    *.tar.gz)
      printf '%s\n' "$base" | grep -Eq "$tarball_re" ||
        { echo "sign: $f isn't crew-<agent|cache>-<version>-<target>.tar.gz" >&2; exit 1; }
      ;;
    *) echo "sign: $f isn't a .manifest.json or a release .tar.gz" >&2; exit 1 ;;
  esac
  [ -f "$f" ] || { echo "sign: no $f" >&2; exit 1; }
done

key_lines() { grep -v '^[[:space:]]*#' | tr -d ' \t\r' | grep -v '^$' || true; }
if [ -n "$key_file" ]; then
  seed=$(key_lines < "$key_file")
else
  seed=$(printf '%s\n' "${CREW_RELEASE_SIGNING_KEY:-}" | key_lines)
fi
[ -n "$seed" ] || { echo "sign: no key (CREW_RELEASE_SIGNING_KEY or --key-file)" >&2; exit 1; }

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! printf '%s' "$seed" | openssl base64 -d -A > "$tmp/seed" 2>/dev/null ||
  [ "$(wc -c < "$tmp/seed" | tr -d ' ')" != 32 ]; then
  echo "sign: the key must be a base64 32-byte ed25519 seed" >&2
  exit 1
fi

# The seed as a PKCS#8 private key: a fixed 16-byte DER prefix, then it.
{ printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'; cat "$tmp/seed"; } > "$tmp/key.der"
openssl pkey -inform DER -in "$tmp/key.der" -out "$tmp/key.pem"
public=$(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 | openssl base64 -A)

test_public=$(key_lines < "$here/keys/test-signing.pub")
if [ "$public" = "$test_public" ]; then
  if [ "$release" = 1 ]; then
    echo "sign: refusing the development test key for a release" >&2
    exit 1
  fi
  echo "sign: signing with the TEST KEY (development only)" >&2
fi
if [ -n "$public_file" ] && [ "$public" != "$(key_lines < "$public_file")" ]; then
  echo "sign: the signing key's public half ($public) isn't the key in $public_file" >&2
  exit 1
fi

# sign MESSAGE_FILE OUT: the base64 signature, written whole or not at all.
# The umask kept the key material private; what's written here is public.
sign() {
  openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$1" -out "$tmp/sig"
  openssl base64 -A < "$tmp/sig" > "$2.part"
  chmod 0644 "$2.part"
  mv "$2.part" "$2"
}

for f in "$@"; do
  base=$(basename -- "$f")
  case "$base" in
    *.manifest.json)
      sig=${f%.manifest.json}.manifest.sig
      { printf 'crew-manifest-v1\n'; cat "$f"; } > "$tmp/message"
      sign "$tmp/message" "$sig"
      ;;
    *)
      version=$(printf '%s\n' "$base" | sed -E "s/$tarball_re/\\2/")
      target=$(printf '%s\n' "$base" | sed -E "s/$tarball_re/\\4/")
      sha=$(openssl dgst -sha256 -r "$f" | cut -d ' ' -f 1)
      printf '%s  %s\n' "$sha" "$base" > "$f.sha256.part"
      chmod 0644 "$f.sha256.part"
      mv "$f.sha256.part" "$f.sha256"
      printf 'crew-release-v1\n%s\n%s\n%s' "$version" "$target" "$sha" > "$tmp/message"
      sig=$f.sig
      sign "$tmp/message" "$sig"
      ;;
  esac
  echo "sign: wrote $sig (public key $public)"
done
