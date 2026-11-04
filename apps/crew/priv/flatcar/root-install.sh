#!/bin/sh
# Installs an agent update's root half (docs/crew_spec.md §10.8, §20.2),
# from crew-root-install.service, which crew-root-install.path starts
# when the agent stages a request in /srv/crew/agent/update/.
#
# Everything root runs comes from /srv/crew/root/<version>, and only from
# tarballs root has checked itself: agent/ is the agent's, so nothing in
# it is trusted. Root takes the request out of it, copies the staged
# tarballs into a directory of its own, checks each against the SHA-256
# the request names and its ed25519 signature against the release key
# the Ignition wrote (/etc/crew-box/release-key.pem), and then, as the
# first install does (lib.sh's root_half), puts crew-vmctl, jailer,
# Firecracker, the ruleset and crew-vmctl's units in root/<version>. It
# moves root/current, puts the units in place (root-units.sh), and loads
# the packet filter again if the ruleset changed. The agent then moves
# its own current, restarts crew-cache and exits.
#
# The request (CrewAgent.Updater.RootStep), one KEY=value per line:
# NONCE, VERSION, TARGET, AGENT_SHA256, AGENT_SIG, CACHE_SHA256 and
# CACHE_SIG. The answer, in root/update.result (0644):
#
#   ok <nonce> <version>
#   error <nonce> <why>
#
# CREW_BOX_ETC and CREW_BOX_DATA move /etc/crew-box and /srv/crew, for
# the control plane's tests.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

stage="$data/agent/update"
root_dir="$data/root"
result="$root_dir/update.result"

root=""
if [ "$(id -u)" -eq 0 ]; then root=1; fi

tmp="$root_dir/.update.$$"
rm -rf "$tmp"
mkdir -m 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

# take <name>: moves agent/update/<name> into root's directory before
# anything looks at it, so the agent can't swap it for a link or a FIFO
# between the check and the read (rename moves a link, never what it
# points at). It counts only if what arrived is a plain file.
take() {
  mv -f "$stage/$1" "$tmp/$1.taken" 2>/dev/null || true
  rm -f "$stage/$1"
  [ -f "$tmp/$1.taken" ] && [ ! -L "$tmp/$1.taken" ]
}

# The request is the path unit's trigger, so it's taken whatever it
# holds: it can't start this again. A link, or anything but a file, is
# no request.
if take request; then head -c 4096 "$tmp/request.taken" > "$tmp/request"; fi
if [ ! -s "$tmp/request" ]; then
  echo "no request to act on"
  exit 0
fi

# Each field is the first line naming it, and only one line: one_line
# (lib.sh) refuses anything a value doesn't need before matching.
field() { sed -n "s/^$1=//p" "$tmp/request" | head -n 1; }

nonce=$(field NONCE)
one_line "$nonce" '[0-9a-f]{32}' || fail "the update request has no nonce, so there's no one to answer"

# answer ok|error <text>: for the agent, which waits for its nonce.
answer() {
  status=$1
  shift
  printf '%s %s %s\n' "$status" "$nonce" "$*" > "$result.new"
  chmod 0644 "$result.new"
  mv -f "$result.new" "$result"
}
refuse() {
  answer error "$*"
  fail "$*"
}

version=$(field VERSION)
target=$(field TARGET)
agent_sha=$(field AGENT_SHA256)
agent_sig=$(field AGENT_SIG)
cache_sha=$(field CACHE_SHA256)
cache_sig=$(field CACHE_SIG)

release_version "$version" || refuse "the request's version isn't a release version"
case "$(uname -m)" in
  x86_64 | amd64) mine=linux-amd64 ;;
  aarch64 | arm64) mine=linux-arm64 ;;
  *) mine=unknown ;;
esac
[ "$target" = "$mine" ] || refuse "the request's target isn't this box's ($mine)"
for sha in "$agent_sha" "$cache_sha"; do
  one_line "$sha" '[0-9a-f]{64}' || refuse "the request has a SHA-256 that isn't one"
done
for sig in "$agent_sig" "$cache_sig"; do
  one_line "$sig" '[A-Za-z0-9+/=]{1,128}' || refuse "the request has a signature that isn't base64"
done
[ -s "$etc/release-key.pem" ] ||
  refuse "this box has no release key ($etc/release-key.pem); reprovision it to update"

# The staged tarballs, taken into root's directory and checked there;
# crew_cache's too, so root has seen the whole release it's installing
# (the cache runs as crewcache, from the agent's copy).
for c in agent cache; do
  take "$c.tar.gz" || refuse "the $c tarball isn't staged"
  mv -f "$tmp/$c.tar.gz.taken" "$tmp/$c.tar.gz"
done
check_release agent "$tmp/agent.tar.gz" "$version" "$target" "$agent_sha" "$agent_sig" \
  "$etc/release-key.pem" "$tmp" || refuse "$why"
check_release cache "$tmp/cache.tar.gz" "$version" "$target" "$cache_sha" "$cache_sig" \
  "$etc/release-key.pem" "$tmp" || refuse "$why"

old=$(readlink "$root_dir/current" 2>/dev/null || true)
if [ "$old" = "$version" ]; then
  say "root's half of $version is already installed"
  answer ok "$version"
  exit 0
fi

new="$tmp/release"
mkdir -p "$new"
tar -xzf "$tmp/agent.tar.gz" -C "$new" --no-same-owner || refuse "the agent tarball doesn't unpack"
priv="$tmp/root"
root_half "$new" "$priv" || refuse "$why"
if [ -n "$root" ]; then chown -R root:root "$priv"; fi
chmod -R go-w "$priv"
chmod 0755 "$priv"

rm -rf "${root_dir:?}/$version"
mv "$priv" "$root_dir/$version"
relink "$root_dir" current "$version"

# The units first (crew-vmctl's socket and service, crew-net's), then
# the packet filter if the ruleset changed: through crew-vmctl net-up
# itself, as crew-net runs it, since restarting crew-net would restart
# the agent (Requires=) in the middle of its update. net-up puts back
# vm_pairs for the VMs running.
ruleset_changed() {
  [ -n "$old" ] || return 1
  for f in etc/nft.conf etc/connlimit.rules; do
    cmp -s "$root_dir/$old/$f" "$root_dir/$version/$f" || return 0
  done
  return 1
}

back() {
  if [ -n "$old" ] && [ -d "$root_dir/$old" ]; then
    relink "$root_dir" current "$old"
    CREW_BOX_DATA="$data" sh "$etc/root-units.sh" || true
    "$root_dir/current/bin/crew-vmctl" net-up || true
  fi
  refuse "$*"
}

CREW_BOX_DATA="$data" sh "$etc/root-units.sh" || back "the release's units didn't install"
if ruleset_changed; then
  "$root_dir/current/bin/crew-vmctl" net-up || back "crew-vmctl net-up failed with $version's ruleset"
fi

# Kept: this release, the one before it, and the one the agent would roll
# back to; the rest go.
exact_link "$data/agent/previous" || true
previous=$link
release_version "$previous" || previous=""
for d in "$root_dir"/*; do
  name=$(basename "$d")
  case "$name" in "$version" | "$old" | "$previous" | current | update.result) continue ;; esac
  if release_version "$name"; then rm -rf "${root_dir:?}/$name"; fi
done

say "installed root's half of $version"
answer ok "$version"
