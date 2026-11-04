#!/bin/bash
# Signs a guest image manifest (docs/crew_spec.md §13.1) with openssl and
# nothing else, for CI's sign job, which runs no third-party actions
# (§20.1). It makes exactly the signature CrewProtocol.Auth.sign_manifest
# makes (ed25519 is deterministic): over "crew-manifest-v1\n" followed by
# the manifest's exact bytes, written base64 with no newline to
# <name>.manifest.sig. `mix crew_image.sign` does the same in Elixir.
#
#   sign.sh [--release] [--key-file F] <name>.manifest.json
#
# The key is the base64 32-byte ed25519 seed, from CREW_RELEASE_SIGNING_KEY
# or --key-file (which may have # comments). --release refuses the
# development test key (keys/test-signing.key).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
release=0 key_file=""
while [ $# -gt 1 ]; do
  case "$1" in
    --release) release=1; shift ;;
    --key-file) key_file=$2; shift 2 ;;
    *) break ;;
  esac
done
manifest=${1:?usage: sign.sh [--release] [--key-file F] <name>.manifest.json}
case "$manifest" in *.manifest.json) ;; *) echo "sign: $manifest isn't a .manifest.json" >&2; exit 1 ;; esac
[ -f "$manifest" ] || { echo "sign: no $manifest" >&2; exit 1; }
sig=${manifest%.manifest.json}.manifest.sig

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

{ printf 'crew-manifest-v1\n'; cat "$manifest"; } > "$tmp/message"
openssl pkeyutl -sign -inkey "$tmp/key.pem" -rawin -in "$tmp/message" -out "$tmp/sig"
openssl base64 -A < "$tmp/sig" > "$sig.part"
mv "$sig.part" "$sig"
echo "sign: wrote $sig (public key $public)"
