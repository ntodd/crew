#!/bin/sh
# Installs the release's root units (native/crew-vmctl/etc/systemd:
# crew-net, crew-vmctl's socket and service, site4's timer) from
# /srv/crew/root/current into /etc/systemd/system, from
# crew-root-units.service at every boot and from crew-provision after the
# first install. The OS disk keeps no copy of its own that matters: a
# reprovisioned one gets them back from the data disk here.
#
# /srv/crew/root is root's (crew-agent-install puts the release's root
# half there, with the units pointed at it), so nothing in it is the
# agent's to change. crew-root-install runs this after an update.
#
# CREW_BOX_ETC, CREW_BOX_DATA and CREW_BOX_UNITS move /etc/crew-box,
# /srv/crew and /etc/systemd/system, for the control plane's tests.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
data=${CREW_BOX_DATA:-/srv/crew}
dest=${CREW_BOX_UNITS:-/etc/systemd/system}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

src="$data/root/current/etc/systemd"
[ -d "$src" ] || fail "there's no $src (crew-agent-install makes it)"

owner=""
if [ "$(id -u)" -eq 0 ]; then owner="-o root -g root"; fi

changed=""
for name in $root_units; do
  [ -f "$src/$name" ] || fail "the release has no $name"
  if ! cmp -s "$src/$name" "$dest/$name"; then
    # shellcheck disable=SC2086 # $owner is two options, or none
    install -m 0644 $owner "$src/$name" "$dest/$name"
    changed=1
  fi
done
if [ -n "$changed" ]; then systemctl daemon-reload; fi
systemctl enable crew-net.service crew-vmctl.socket crew-net-site4.timer >/dev/null 2>&1

# Units installed during the boot weren't in its transaction (a new OS
# disk's first boot), so they're started here; on any other boot this
# joins jobs already queued.
systemctl start --no-block crew-vmctl.socket crew-net.service crew-net-site4.timer \
  crew-agent.service crew-cache.service
