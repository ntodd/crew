#!/bin/sh
# Turns a new Flatcar machine into a Crew box (docs/crew_spec.md §12.2),
# from crew-provision.service on the first boot: joins the tailnet with
# the key the control plane put in the Ignition, waits until the control
# plane answers, installs the agent (crew-agent-install.service), starts
# it, and waits for it to enroll with the join token. Then the token and
# the Ignition that carried it are deleted, which also keeps this from
# running again. A failure is retried by the unit.
set -eu

etc=/etc/crew-box
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

env="$etc/provision.env"
key="$etc/tailscale-authkey"
agent=/srv/crew/agent

# CREW_URL, CREW_JOIN_TOKEN and CREW_BOX_NAME.
# shellcheck source=/dev/null
. "$env"

if [ -s "$key" ]; then
  say "joining the tailnet as crew-$CREW_BOX_NAME"
  # tailscaled comes from a system extension and may still be starting.
  i=0
  until tailscale up --auth-key="file:$key" --advertise-tags=tag:crew-box \
    --hostname="crew-$CREW_BOX_NAME" --timeout=2m; do
    i=$((i + 1))
    [ $i -lt 10 ] || fail "couldn't join the tailnet"
    sleep 3
  done
  # Single-use, and spent.
  rm -f "$key"
fi

say "waiting for $CREW_URL"
i=0
until curl -fsS -o /dev/null --max-time 10 "$CREW_URL/healthz"; do
  i=$((i + 1))
  [ $i -lt 60 ] || fail "the control plane at $CREW_URL doesn't answer"
  sleep 5
done

# Idempotent: it does nothing once agent/current is there.
systemctl start crew-agent-install.service ||
  fail "the agent's install failed (journalctl -u crew-agent-install)"

say "starting the agent"
# On a retry the agent may have hit its start limit.
systemctl reset-failed crew-agent.service 2>/dev/null || true
# crew-agent wants crew-cache, and starts without it if it fails: the
# agent reports the cache's health, and the box enrolls either way.
systemctl start crew-net.service crew-agent.service ||
  fail "the agent didn't start (journalctl -u crew-net -u crew-agent)"

say "waiting for the agent to enroll"
i=0
until [ -s "$agent/identity.json" ]; do
  i=$((i + 1))
  [ $i -lt 90 ] || fail "the agent didn't enroll within 3 minutes (journalctl -u crew-agent)"
  sleep 2
done

# The agent makes its directory 0700 when it saves its identity; crewcache
# reaches its release through it (agent/current/cache), and can't list it.
chmod 0711 "$agent"

# Spent: the token, and the config that carried it and the Tailscale key
# (on bare metal and on a Mac, Flatcar keeps it in the OEM partition).
sed -i '/^CREW_JOIN_TOKEN=/d' "$agent/env"
rm -f "$env" /oem/config.ign
say "enrolled"
