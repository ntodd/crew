#!/bin/bash
# Builds a Linux box's agent and cache tarballs (spec §20.1 items 3 and 4):
#
#   crew-agent-<version>-<target>.tar.gz   the crew_agent release (bin/crew_agent),
#                                          crew-vmctl, the pinned firecracker and
#                                          jailer, etc/nft.conf, etc/connlimit.rules
#                                          and etc/systemd/
#   crew-cache-<version>-<target>.tar.gz   the crew_cache release (bin/crew_cache)
#
# Both unpack at their root, as the Flatcar install expects (docs/architecture.md,
# "Flatcar box notes"). The Elixir releases build in the pinned Elixir image for
# the target's arch (ERTS included); crew-vmctl builds with Go from vendor/.
#
#   packaging/release/build-linux.sh linux-arm64 0.1.0 OUT_DIR
#
# Signing is a separate step (mix crew.sign), as in CI's sign job.
set -euo pipefail

target=${1:?usage: build-linux.sh linux-amd64|linux-arm64 VERSION OUT_DIR}
version=${2:?version}
out=${3:?out dir}
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/images/guest/versions.env"

case $target in
  linux-amd64) platform=linux/amd64 goarch=amd64 fcarch=x86_64 ;;
  linux-arm64) platform=linux/arm64 goarch=arm64 fcarch=aarch64 ;;
  *) echo "build-linux: no target $target" >&2; exit 1 ;;
esac

mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The Elixir releases, from a clean copy of the sources (no host _build).
for app in crew_agent crew_cache; do
  echo "build-linux: $app for $target"
  docker run --rm --platform "$platform" \
    -v "$root/apps/crew_protocol:/src/crew_protocol:ro" -v "$root/apps/$app:/src/$app:ro" \
    -v "$work:/out" -e MIX_ENV=prod -e APP="$app" -e VERSION="$version" \
    "$ELIXIR_IMAGE" bash -euc '
      # muontrap builds a small C port: the image has no compiler.
      command -v make >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential >/dev/null; }
      mkdir -p /w && cp -r /src/crew_protocol "/src/$APP" /w/ && rm -rf /w/*/_build /w/*/deps
      cd "/w/$APP"
      mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
      mix deps.get --only prod >/dev/null
      mix release --overwrite --quiet
      cp -a "_build/prod/rel/$APP" "/out/$APP"
      chown -R "$(stat -c %u /out):$(stat -c %g /out)" "/out/$APP"'
done

# crew-vmctl, static, from the vendored module.
make -C "$root/native" crew-vmctl VERSION="$version" >/dev/null

# Firecracker and its jailer, pinned and checked (they run on the box, never here).
"$root/native/crew-vmctl/fetch-firecracker.sh" "$work/firecracker" "$fcarch"

agent="$work/crew_agent"
install -m 0755 "$root/native/crew-vmctl/bin/linux-$goarch/crew-vmctl" "$agent/bin/crew-vmctl"
install -m 0755 "$work/firecracker/firecracker" "$agent/bin/firecracker"
install -m 0755 "$work/firecracker/jailer" "$agent/bin/jailer"
mkdir -p "$agent/etc/systemd"
install -m 0644 "$root/native/crew-vmctl/etc/nft.conf" "$root/native/crew-vmctl/etc/connlimit.rules" "$agent/etc/"
install -m 0644 "$root/native/crew-vmctl/etc/systemd/"* "$agent/etc/systemd/"

# Reproducible-ish: sorted entries, no owners, a fixed time.
pack() {
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00:00Z' \
    -C "$1" -czf "$2" . 2>/dev/null || COPYFILE_DISABLE=1 tar -C "$1" -czf "$2" .
}
pack "$agent" "$out/crew-agent-$version-$target.tar.gz"
pack "$work/crew_cache" "$out/crew-cache-$version-$target.tar.gz"
ls -la "$out"
