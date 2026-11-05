# The mac-vz box's cache VM (docs/crew_spec.md §12.3, §15.6), every
# boot, as root: puts the management token on the data disk, and on the
# first boot installs crew_cache from the release the Ignition names,
# checked against its SHA-256 and the release key the Ignition embeds.
# A new OS disk (reprovision) carries neither: the data disk has both.
#
# CREW_BOX_ETC and CREW_BOX_DATA move /etc/crew-box and /srv/crew, for
# the control plane's tests.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

root=""
if [ "$(id -u)" -eq 0 ]; then root=1; fi

# The cache's management token: the Ignition's, kept on the data disk.
mkdir -p "$data/cachevm"
chmod 0700 "$data/cachevm"
if [ -s "$etc/cache-mgmt.env" ]; then
  umask 077
  cp "$etc/cache-mgmt.env" "$data/cachevm/.mgmt.env.new"
  chmod 0600 "$data/cachevm/.mgmt.env.new"
  mv -f "$data/cachevm/.mgmt.env.new" "$data/cachevm/mgmt.env"
  umask 022
fi
[ -s "$data/cachevm/mgmt.env" ] || fail "the cache's management token isn't on the data disk; reprovision with the box page's Ignition"

# The store, crewcache's.
mkdir -p "$data/cache"
if [ -n "$root" ]; then chown crewcache:crewcache "$data/cache"; fi
chmod 0750 "$data/cache"

releases="$data/release"
if [ -e "$releases/current" ]; then
  exact_link "$releases/current" || fail "$releases/current isn't a link"
  release_version "$link" || fail "$releases/current points at something that isn't a release"
  say "crew_cache is installed ($link)"
  exit 0
fi

[ -f "$etc/release.env" ] || fail "no crew_cache is installed and the Ignition names no release"
# CREW_VERSION, CREW_TARGET, CREW_CACHE_{URL,SHA256,SIG} and
# CREW_RELEASE_KEY_FINGERPRINT.
# shellcheck source=/dev/null
. "$etc/release.env"
release_version "$CREW_VERSION" || fail "the release version in release.env isn't one"
case "$CREW_TARGET" in linux-amd64 | linux-arm64) ;; *) fail "the target '$CREW_TARGET' isn't one" ;; esac

mkdir -p "$releases"
if [ -n "$root" ]; then chown root:root "$releases"; fi
chmod 0755 "$releases"
tmp="$releases/.install.$$"
rm -rf "$tmp"
mkdir -m 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

say "downloading crew_cache $CREW_VERSION ($CREW_TARGET)"
curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/cache.tar.gz" "$CREW_CACHE_URL" </dev/null ||
  fail "couldn't download crew_cache from $CREW_CACHE_URL"
check_release cache "$tmp/cache.tar.gz" "$CREW_VERSION" "$CREW_TARGET" "$CREW_CACHE_SHA256" \
  "$CREW_CACHE_SIG" "$etc/release-key.pem" "$tmp" || fail "$why ($CREW_RELEASE_KEY_FINGERPRINT)"

mkdir -p "$tmp/release"
tar -xzf "$tmp/cache.tar.gz" -C "$tmp/release" --no-same-owner
[ -x "$tmp/release/bin/crew_cache" ] || fail "the release has no bin/crew_cache"
if [ -n "$root" ]; then chown -R root:root "$tmp/release"; fi
chmod -R go-w "$tmp/release"
chmod 0755 "$tmp/release"
rm -rf "${releases:?}/${CREW_VERSION:?}"
mv "$tmp/release" "$releases/$CREW_VERSION"
relink "$releases" current "$CREW_VERSION"
say "installed crew_cache $CREW_VERSION"
