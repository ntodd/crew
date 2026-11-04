#!/bin/sh
# Installs the Crew agent and crew_cache on a Flatcar box's data disk
# (docs/crew_spec.md §12.2, §20.2), from crew-agent-install.service,
# which crew-provision starts. Idempotent: with agent/current in place it
# does nothing, so a reprovisioned OS disk keeps the installed agent.
#
# The tarballs come from the URLs in the Ignition (the GitHub release's;
# the control plane's in development). Each must match its SHA-256 and
# carry an ed25519 signature by the release key the Ignition embeds,
# over CrewProtocol.Auth.release_message/3's bytes. Then:
#
#   /srv/crew/agent/<version>/          the agent tarball (root's, read-only)
#   /srv/crew/agent/<version>/cache/    the crew_cache tarball
#   /srv/crew/agent/current -> <version>
#   /srv/crew/agent/env                 the agent's settings (0600)
#   /srv/crew/root/<version>/           what root runs: bin/crew-vmctl,
#                                       bin/jailer, bin/firecracker, etc/
#                                       (the ruleset and crew-vmctl's units)
#   /srv/crew/root/current -> <version>
#
# The agent owns agent/ (it updates itself, §20.2), so root never runs
# anything from there: root/ is root's, and the units are pointed at it.
#
# CREW_BOX_ETC and CREW_BOX_DATA move /etc/crew-box and /srv/crew, for
# the control plane's tests.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

# CREW_BOX_NAME and CREW_BOX_TYPE.
# shellcheck source=/dev/null
. "$etc/box.env"
# CREW_VERSION, CREW_TARGET, CREW_{AGENT,CACHE}_{URL,SHA256,SIG},
# CREW_AGENT_SOCKET_URL, CREW_RELEASE_PUBLIC_KEY,
# CREW_RELEASE_KEY_FINGERPRINT and CREW_DEV.
# shellcheck source=/dev/null
. "$etc/release.env"
# The join token, until the box has enrolled.
CREW_JOIN_TOKEN=""
# shellcheck source=/dev/null
if [ -f "$etc/provision.env" ]; then . "$etc/provision.env"; fi

agent="$data/agent"
if [ -e "$agent/current" ]; then
  say "the agent is installed ($(readlink "$agent/current"))"
  exit 0
fi

case "$CREW_VERSION" in "" | *[!0-9A-Za-z.-]*) fail "the release version '$CREW_VERSION' isn't one" ;; esac
case "$CREW_TARGET" in linux-amd64 | linux-arm64) ;; *) fail "the target '$CREW_TARGET' isn't one" ;; esac
[ -d "$agent" ] || fail "$agent isn't there (crew-quota.service makes it)"

root=""
if [ "$(id -u)" -eq 0 ]; then root=1; fi

root_dir="$data/root"
mkdir -p "$root_dir"
if [ -n "$root" ]; then chown root:root "$root_dir"; fi
chmod 0755 "$root_dir"

# On the data disk, not /tmp, which is memory, and in root's directory,
# out of the agent's reach.
tmp="$root_dir/.install.$$"
rm -rf "$tmp"
mkdir -m 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

# fetch <name> <url> <sha256> <signature>
fetch() {
  say "downloading the $1 $CREW_VERSION ($CREW_TARGET)"
  curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/$1.tar.gz" "$2" </dev/null ||
    fail "couldn't download the $1 from $2"
  check_release "$1" "$tmp/$1.tar.gz" "$CREW_VERSION" "$CREW_TARGET" "$3" "$4" \
    "$etc/release-key.pem" "$tmp" || fail "$why ($CREW_RELEASE_KEY_FINGERPRINT)"
}

fetch agent "$CREW_AGENT_URL" "$CREW_AGENT_SHA256" "$CREW_AGENT_SIG"
fetch cache "$CREW_CACHE_URL" "$CREW_CACHE_SHA256" "$CREW_CACHE_SIG"

dest="$agent/$CREW_VERSION"
new="$tmp/release"
mkdir -p "$new/cache"
tar -xzf "$tmp/agent.tar.gz" -C "$new" --no-same-owner
tar -xzf "$tmp/cache.tar.gz" -C "$new/cache" --no-same-owner

# What the agent tarball holds (native/crew-vmctl's README): the agent,
# crew-vmctl, Firecracker's jailer and VMM, the ruleset and the units;
# the cache's, crew_cache. The root half is copied out of the agent's
# release: the binaries root runs, the ruleset, and the units pointed at
# root/current (lib.sh's root_half, which root-install.sh uses too).
[ -x "$new/cache/bin/crew_cache" ] || fail "the release has no cache/bin/crew_cache"
priv="$tmp/root"
root_half "$new" "$priv" || fail "$why"

# Both root's and read-only: crew_cache runs as crewcache from agent/,
# and the agent from agent/ as itself.
for d in "$new" "$priv"; do
  if [ -n "$root" ]; then chown -R root:root "$d"; fi
  chmod -R go-w "$d"
  chmod 0755 "$d"
done
rm -rf "$dest" "${root_dir:?}/${CREW_VERSION:?}"
mv "$priv" "$root_dir/$CREW_VERSION"
mv "$new" "$dest"
ln -sfn "$CREW_VERSION" "$root_dir/current"
ln -s "$CREW_VERSION" "$agent/current"
rm -f "$agent/previous" "$agent/update-pending"

# The agent's settings (§21.2). systemd reads them as root; the agent
# never needs to.
if [ ! -s "$agent/env" ] || [ -n "$CREW_JOIN_TOKEN" ]; then
  umask 077
  {
    echo "CREW_URL=$CREW_AGENT_SOCKET_URL"
    echo "CREW_BOX_NAME=$CREW_BOX_NAME"
    echo "CREW_DATA_DIR=$data"
    echo "CREW_DRIVER=firecracker"
    echo "CREW_CACHE_MGMT_URL=http://127.0.0.1:7780"
    echo "CREW_RELEASE_PUBLIC_KEY=$CREW_RELEASE_PUBLIC_KEY"
    if [ "${CREW_DEV:-}" = 1 ]; then echo "CREW_DEV=1"; fi
    if [ -n "$CREW_JOIN_TOKEN" ]; then echo "CREW_JOIN_TOKEN=$CREW_JOIN_TOKEN"; fi
  } > "$agent/env.new"
  if [ -n "$root" ]; then chown root:root "$agent/env.new"; fi
  chmod 0600 "$agent/env.new"
  mv "$agent/env.new" "$agent/env"
fi

say "installed the agent $CREW_VERSION"
