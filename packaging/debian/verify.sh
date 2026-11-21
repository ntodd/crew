#!/bin/bash
# Verify the detached signature on the checksum, then the package itself.
set -euo pipefail
deb=${1:?path to crew-worker .deb}
key=${2:?path to trusted Crew release-key.pub}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; grep -v '^#' "$key" | openssl base64 -d -A; } > "$tmp/key.der"
openssl base64 -d -A -in "$deb.sig" -out "$tmp/sig"
openssl pkeyutl -verify -pubin -keyform DER -inkey "$tmp/key.der" -rawin -in "$deb.sha256" -sigfile "$tmp/sig"
(cd "$(dirname "$deb")" && sha256sum -- "$(basename "$deb")") > "$tmp/actual"
cmp "$tmp/actual" "$deb.sha256"
