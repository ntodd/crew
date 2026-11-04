#!/bin/bash
# Builds a Mac's agent tarball (spec §20.1 item 3, darwin-arm64):
#
#   crew-agent-<version>-darwin-arm64.tar.gz   the crew_agent release (bin/crew_agent),
#                                              bin/crew-vz (ad-hoc signed with the
#                                              Virtualization entitlement, as native/'s
#                                              Makefile signs it), bin/crew-launch,
#                                              share/sandbox.sb, launchd/ (the two
#                                              plists), install-macos.sh and VERSION
#
# It unpacks at its root, as install-macos.sh and the agent's updater expect
# (docs/architecture.md, "Update notes"). Mirrors build-linux.sh, with the
# same arguments, but natively: an Apple-silicon Mac builds the release with
# the Erlang and Elixir mise.toml pins (ERTS included), which it installs
# itself through mise (setup-beam has no macOS; Homebrew installs mise when
# it's missing), and crew-vz with cgo ($GO, as native/'s Makefile). There's
# no crew_cache for macOS; a Mac's cache runs in its cache VM (§12.3).
#
#   packaging/release/build-darwin.sh darwin-arm64 0.1.0 OUT_DIR
#
# MIX_ENV=dev builds a development release, which keeps the null driver
# (the e2e update test's agents). Signing is a separate step (mix crew.sign),
# as in CI's sign job; packaging/release/smoke.sh checks the tarball first.
set -euo pipefail

target=${1:?usage: build-darwin.sh darwin-arm64 VERSION OUT_DIR}
version=${2:?version}
out=${3:?out dir}
root="$(cd "$(dirname "$0")/../.." && pwd)"
env=${MIX_ENV:-prod}

[ "$target" = darwin-arm64 ] || { echo "build-darwin: no target $target" >&2; exit 1; }
[ "$(uname -s)-$(uname -m)" = Darwin-arm64 ] || { echo "build-darwin: needs an Apple-silicon Mac" >&2; exit 1; }
[[ $version =~ ^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-[0-9A-Za-z.]{1,32})?$ ]] ||
  { echo "build-darwin: '$version' isn't a release version" >&2; exit 1; }

mkdir -p "$out" "$root/tmp"
out="$(cd "$out" && pwd)"
# Inside the repository, so mise finds its pins.
work="$(mktemp -d "$root/tmp/build-darwin.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The pinned Erlang and Elixir.
if ! command -v mise >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || { echo "build-darwin: needs mise (or Homebrew to install it)" >&2; exit 1; }
  brew install mise
fi
(cd "$root" && mise install erlang elixir)
run() { mise exec -- "$@"; }

# The release, from a clean copy of the sources (no host _build or deps).
echo "build-darwin: crew_agent $version ($env)"
for app in crew_protocol crew_agent; do
  rsync -a --exclude _build --exclude deps --exclude tmp "$root/apps/$app/" "$work/$app/"
done
(
  cd "$work/crew_agent"
  export MIX_ENV="$env" CREW_VERSION="$version"
  run mix local.hex --force --if-missing >/dev/null
  run mix local.rebar --force --if-missing >/dev/null
  run mix deps.get --only "$env" >/dev/null
  run mix release --overwrite --quiet
)
rel="$work/crew_agent/_build/$env/rel/crew_agent"

# crew-vz, from the vendored module, signed as the Makefile signs it.
echo "build-darwin: crew-vz $version"
make -C "$root/native" crew-vz VERSION="$version" >/dev/null
codesign --verify "$root/native/crew-vz/bin/crew-vz"

install -m 0755 "$root/native/crew-vz/bin/crew-vz" "$rel/bin/crew-vz"
install -m 0755 "$root/packaging/macos/crew-launch" "$rel/bin/crew-launch"
mkdir -p "$rel/share" "$rel/launchd"
install -m 0644 "$root/native/crew-vz/sandbox.sb" "$rel/share/sandbox.sb"
install -m 0644 "$root/packaging/macos/launchd/com.crew.agent.plist" "$root/packaging/macos/launchd/com.crew.vzd.plist" "$rel/launchd/"
install -m 0755 "$root/packaging/macos/install-macos.sh" "$rel/install-macos.sh"
echo "$version" > "$rel/VERSION"

# The agent's updater takes files and directories only.
if find "$rel" -type l | grep -q .; then
  echo "build-darwin: the release holds links, which an update refuses:" >&2
  find "$rel" -type l >&2
  exit 1
fi

# No owners, no extended attributes or AppleDouble files (crew-vz's
# signature is in the binary itself).
COPYFILE_DISABLE=1 tar --no-xattrs --uid 0 --gid 0 --uname root --gname wheel \
  -C "$rel" -czf "$out/crew-agent-$version-$target.tar.gz" .
ls -la "$out/crew-agent-$version-$target.tar.gz"
