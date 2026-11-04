#!/bin/sh
# Rolls the agent back to its previous release (Foreman's
# foreman-agent-rollback, docs/crew_spec.md §20.2), from
# crew-agent-rollback.service, crew-agent's OnFailure: an update keeps
# the release it replaced in `previous` until the new one joins, and one
# that keeps crashing is switched back. crew_cache moves with it, since
# it's the same release, and so does the root half in /srv/crew/root
# (crew-vmctl, the ruleset and their units) when it has that version. A
# first install has nothing to go back to.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

cd /srv/crew/agent
if [ ! -L previous ]; then
  echo "no previous release to roll back to"
  exit 0
fi

target=$(readlink previous)
case "$target" in "" | */* | *[!0-9A-Za-z.-]*) fail "previous points at '$target', which isn't a release" ;; esac
# mv -T: `current` points at a directory, which plain mv would move into.
ln -sfn "$target" current.rollback
mv -Tf current.rollback current
rm -f previous update-pending
say "rolled the agent back to $target"

if [ -d "/srv/crew/root/$target" ]; then
  ln -sfn "$target" /srv/crew/root/current.rollback
  mv -Tf /srv/crew/root/current.rollback /srv/crew/root/current
  sh /etc/crew-box/root-units.sh
  # The ruleset that release's crew-vmctl verifies against.
  systemctl try-restart crew-net.service || true
fi

systemctl reset-failed crew-agent.service crew-cache.service || true
systemctl restart crew-cache.service || true
systemctl start crew-agent.service
