#!/bin/sh
# Rolls the agent back to its previous release (Foreman's
# foreman-agent-rollback, docs/crew_spec.md §20.2), from
# crew-agent-rollback.service, crew-agent's OnFailure: an update keeps
# the release it replaced in `previous` until the new one joins, and one
# that keeps crashing, or exits 75 because it hasn't joined within 5
# minutes (RestartPreventExitStatus), is switched back. crew_cache moves
# with it, since it's the same release, and so does the root half in
# /srv/crew/root (crew-vmctl, the ruleset and their units) when it has
# that version. A first install has nothing to go back to.
#
# The update's marker is renamed `rolled-back`: the release that comes
# back reports the update failed when it joins (CrewAgent.Updater).
#
# CREW_BOX_ETC and CREW_BOX_DATA move /etc/crew-box and /srv/crew, for
# the control plane's tests.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

agent="$data/agent"
if [ ! -L "$agent/previous" ]; then
  echo "no previous release to roll back to"
  exit 0
fi

target=$(readlink "$agent/previous")
release_version "$target" || fail "previous points at '$target', which isn't a release"
relink "$agent" current "$target"
rm -f "$agent/previous" "$agent/crashes"
if [ -f "$agent/update-pending" ]; then mv -f "$agent/update-pending" "$agent/rolled-back"; fi
say "rolled the agent back to $target"

if [ -d "$data/root/$target" ]; then
  relink "$data/root" current "$target"
  CREW_BOX_DATA="$data" sh "$etc/root-units.sh"
  # The ruleset that release's crew-vmctl verifies against.
  systemctl try-restart crew-net.service || true
fi

systemctl reset-failed crew-agent.service crew-cache.service || true
systemctl restart crew-cache.service || true
systemctl start crew-agent.service
