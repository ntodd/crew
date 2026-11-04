#!/bin/sh
# Says on the consoles how a boot of an installed box went, from
# crew-box-status.service after the agent starts (docs/crew_spec.md
# §12.2): every boot after the first, and the first boot of a
# reprovisioned OS disk, where the launchers' `crew-box reimage` waits
# for "crew-box: agent started". The first boot of a new box says
# "crew-box: enrolled" instead (provision.sh).
set -u

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

agent=/srv/crew/agent
if ! mountpoint -q /srv/crew; then
  say "the data disk isn't mounted (journalctl -u crew-format-data -u srv-crew.mount)"
elif [ ! -e "$agent/current" ]; then
  say "there's no agent on the data disk; add the box again with a new join token"
elif [ ! -s "$agent/identity.json" ]; then
  say "the agent on the data disk never enrolled; add the box again with a new join token"
elif systemctl is-active --quiet crew-agent.service; then
  running=$(readlink "$agent/current" || true)
  release_version "$running" || running="not a release"
  say "agent started ($running)"
else
  say "the agent didn't start (journalctl -u crew-agent)"
fi
