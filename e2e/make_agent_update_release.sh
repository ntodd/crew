#!/bin/sh
# The agent releases e2e/tests/13-agent-update.spec.js updates a box between
# (§20.2), added to the control plane's release directory
# (CREW_AGENT_RELEASE_DIR) and signed with the development test key, as
# CI's sign job signs them (mix crew.sign):
#
#   0.9.0, 0.9.1   real darwin-arm64 agent releases, built for development
#                  (the null driver) by packaging/release/build-darwin.sh
#   0.9.2-rc.1     a release whose agent exits at once, which crew-launch
#                  rolls back; a prerelease, so boxes only get it pinned
#
# The two builds are kept in tmp/e2e/agent-update/ between runs: set
# E2E_AGENT_UPDATE_REBUILD=1 (or delete it) after changing the agent.
#
#   e2e/make_agent_update_release.sh <release dir>
set -eu

dir=${1:?usage: make_agent_update_release.sh <release dir>}
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/tmp/e2e/agent-update"
mkdir -p "$cache" "$dir"

for v in 0.9.0 0.9.1; do
  f="crew-agent-$v-darwin-arm64.tar.gz"
  if [ -n "${E2E_AGENT_UPDATE_REBUILD:-}" ] || [ ! -f "$cache/$f" ]; then
    MIX_ENV=dev "$root/packaging/release/build-darwin.sh" darwin-arm64 "$v" "$cache"
  fi
  cp "$cache/$f" "$dir/$f"
done

stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/bin" "$stub/share"
printf '#!/bin/sh\necho "crew_agent 0.9.2-rc.1 crashes at start" >&2\nexit 1\n' > "$stub/bin/crew_agent"
printf '#!/bin/sh\nexit 1\n' > "$stub/bin/crew-vz"
cp "$root/packaging/macos/crew-launch" "$stub/bin/crew-launch"
chmod 0755 "$stub/bin/crew_agent" "$stub/bin/crew-vz" "$stub/bin/crew-launch"
cp "$root/native/crew-vz/sandbox.sb" "$stub/share/sandbox.sb"
echo 0.9.2-rc.1 > "$stub/VERSION"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$stub" -czf "$dir/crew-agent-0.9.2-rc.1-darwin-arm64.tar.gz" .

cd "$root/images/guest/tools"
if command -v mise >/dev/null 2>&1; then mise exec -- mix crew.sign "$dir"; else mix crew.sign "$dir"; fi
