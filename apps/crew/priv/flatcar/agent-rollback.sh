#!/bin/sh
# Rolls the agent back to its previous release (Foreman's
# foreman-agent-rollback, docs/crew_spec.md §20.2), from
# crew-agent-rollback.service, crew-agent's OnFailure: an update keeps
# the release it replaced in `previous` until the new one joins, and one
# that keeps crashing is switched back. crew_cache moves with it, since
# it's the same release. A first install has nothing to go back to.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

cd /srv/crew/agent
if [ ! -L previous ]; then
  echo "no previous release to roll back to"
  exit 0
fi

target=$(readlink previous)
# mv -T: `current` points at a directory, which plain mv would move into.
ln -sfn "$target" current.rollback
mv -Tf current.rollback current
rm -f previous update-pending
say "rolled the agent back to $target"
systemctl reset-failed crew-agent.service crew-cache.service || true
systemctl restart crew-cache.service || true
systemctl start crew-agent.service
