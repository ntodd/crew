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

# On the data disk, not /tmp, which is memory.
tmp="$agent/.install.$$"
rm -rf "$tmp"
mkdir -m 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

sha256() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

# fetch <name> <url> <sha256> <signature>
fetch() {
  say "downloading the $1 $CREW_VERSION ($CREW_TARGET)"
  curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/$1.tar.gz" "$2" </dev/null ||
    fail "couldn't download the $1 from $2"
  [ "$(sha256 "$tmp/$1.tar.gz")" = "$3" ] || fail "the $1 doesn't match its SHA-256"
  printf 'crew-release-v1\n%s\n%s\n%s' "$CREW_VERSION" "$CREW_TARGET" "$3" > "$tmp/$1.msg"
  printf '%s' "$4" | openssl base64 -d -A > "$tmp/$1.sig" 2>/dev/null ||
    fail "the $1's signature isn't base64"
  openssl pkeyutl -verify -pubin -inkey "$etc/release-key.pem" -rawin \
    -in "$tmp/$1.msg" -sigfile "$tmp/$1.sig" >/dev/null 2>&1 ||
    fail "the $1's signature doesn't verify against the release key ($CREW_RELEASE_KEY_FINGERPRINT)"
}

fetch agent "$CREW_AGENT_URL" "$CREW_AGENT_SHA256" "$CREW_AGENT_SIG"
fetch cache "$CREW_CACHE_URL" "$CREW_CACHE_SHA256" "$CREW_CACHE_SIG"

dest="$agent/$CREW_VERSION"
new="$tmp/release"
mkdir -p "$new/cache"
tar -xzf "$tmp/agent.tar.gz" -C "$new" --no-same-owner
tar -xzf "$tmp/cache.tar.gz" -C "$new/cache" --no-same-owner
for f in bin/crew_agent bin/crew-vmctl cache/bin/crew_cache; do
  [ -x "$new/$f" ] || fail "the release has no $f"
done
[ -f "$new/etc/nft.conf" ] || fail "the release has no etc/nft.conf"

# Root's and read-only: crew-vmctl and the firewall rules run as root from
# here, and crew_cache as crewcache.
if [ -n "$root" ]; then chown -R root:root "$new"; fi
chmod -R go-w "$new"
chmod 0755 "$new"
rm -rf "$dest"
mv "$new" "$dest"
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
    echo "CREW_RELEASE_PUBLIC_KEY=$CREW_RELEASE_PUBLIC_KEY"
    if [ "${CREW_DEV:-}" = 1 ]; then echo "CREW_DEV=1"; fi
    if [ -n "$CREW_JOIN_TOKEN" ]; then echo "CREW_JOIN_TOKEN=$CREW_JOIN_TOKEN"; fi
  } > "$agent/env.new"
  if [ -n "$root" ]; then chown root:root "$agent/env.new"; fi
  chmod 0600 "$agent/env.new"
  mv "$agent/env.new" "$agent/env"
fi

say "installed the agent $CREW_VERSION"
