#!/bin/sh
# Lays out a Flatcar box's data disk (docs/crew_spec.md §10.1, §10.8,
# §12.4), from crew-quota.service on every boot, once /srv/crew is
# mounted: the directories and who owns them, and three XFS project
# quotas, so one area filling up can't starve the others:
#
#   project 10  vms/ + jail/      the clone area: half the disk
#   project 11  cache/            crew_cache's store: a quarter
#   project 12  agent/ + images/  the rest
#
# The limits follow the disk's size at each boot. crew_cache is told its
# share (CREW_CACHE_MAX_GIB in /run/crew-box/cache.env), with room left
# for its index and temporary files.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

data=/srv/crew
mountpoint -q "$data" || fail "the data disk isn't mounted at $data"

dir() { # mode owner path
  [ -d "$3" ] || mkdir "$3"
  chown "$2" "$3"
  chmod "$1" "$3"
}

dir 0755 root:root "$data"
# The agent's: identity, settings, releases. 0711 so crewcache reaches its
# release in agent/current/cache without listing anything.
dir 0711 _crewagent:_crewagent "$data/agent"
dir 0750 _crewagent:crewvm "$data/vms"
dir 0750 _crewagent:_crewagent "$data/images"
dir 0711 root:root "$data/jail"
dir 0750 crewcache:crewcache "$data/cache"
# tailscaled's state, so the node keeps its identity across a
# reprovisioned OS disk (§12.2).
dir 0700 root:root "$data/tailscale"

total_mib=$(df -Pm "$data" | awk 'NR == 2 { print $2 }')
case "$total_mib" in "" | *[!0-9]*) fail "couldn't read the data disk's size" ;; esac
clone_mib=$((total_mib / 2))
cache_mib=$((total_mib / 4))
rest_mib=$((total_mib - clone_mib - cache_mib))

cache_gib=$((cache_mib * 9 / 10 / 1024))
[ "$cache_gib" -ge 1 ] || cache_gib=1
mkdir -p /run/crew-box
echo "CREW_CACHE_MAX_GIB=$cache_gib" > /run/crew-box/cache.env

project() { # id path...
  id=$1
  shift
  for d in "$@"; do
    if [ "$(xfs_io -c lsproj "$d" 2>/dev/null | sed -n 's/^projid = //p')" != "$id" ]; then
      xfs_quota -x -c "project -s -p $d $id" "$data" >/dev/null || return 1
    fi
  done
}

# The directories above are what the box needs to run; a quota that
# can't be set is said loudly, and doesn't keep the box (or tailscaled,
# whose state is here) down.
if project 10 "$data/vms" "$data/jail" &&
  project 11 "$data/cache" &&
  project 12 "$data/agent" "$data/images" &&
  xfs_quota -x -c "limit -p bhard=${clone_mib}m 10" "$data" &&
  xfs_quota -x -c "limit -p bhard=${cache_mib}m 11" "$data" &&
  xfs_quota -x -c "limit -p bhard=${rest_mib}m 12" "$data"; then
  echo "data disk: ${total_mib} MiB; clones ${clone_mib}, cache ${cache_mib}, agent and images ${rest_mib}"
else
  say "couldn't set the data disk's quotas; one area filling up can starve the others (journalctl -u crew-quota)"
fi
