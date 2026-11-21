#!/bin/bash
# Both projects use Foreman's release manifest. Advance the commit to
# adopt a reviewed Foreman pin; no moving branch is a build input.
set -euo pipefail
out=${1:?output file}
foreman=4c8232d6932d5118bdb8aba379101179e1b1538e
manifest=https://raw.githubusercontent.com/ntodd/foreman/$foreman/apps/foreman_agent/rel/tools/cloud-hypervisor.sha256
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' -fsSL --retry 3 "$manifest" -o "$tmp/manifest"
line=$(grep -v '^#' "$tmp/manifest")
[[ "$line" =~ ^([0-9a-f]{64})[[:space:]]+(v[0-9]+(\.[0-9]+)+/cloud-hypervisor-static)$ ]] || {
  echo "Invalid Foreman Cloud Hypervisor manifest" >&2
  exit 1
}
digest=${BASH_REMATCH[1]}
asset=${BASH_REMATCH[2]}
curl --proto '=https' -fsSL --retry 3 "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/$asset" -o "$tmp/cloud-hypervisor"
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$tmp/cloud-hypervisor")
else
  actual=$(shasum -a 256 "$tmp/cloud-hypervisor")
fi
[[ ${actual%% *} = "$digest" ]] || { echo "Cloud Hypervisor digest mismatch" >&2; exit 1; }
install -m 0755 "$tmp/cloud-hypervisor" "$out"
