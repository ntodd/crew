#!/bin/sh
# Formats a Flatcar box's data disk (docs/crew_spec.md §12.2, §12.4), from
# crew-format-data.service, at boot, when no disk has Crew's label yet. It
# only ever formats an empty disk: one with no filesystem and no partition
# table, while no disk carries the label. srv-crew.mount mounts the disk
# by that label and doesn't depend on this, so a disk that comes back
# under another name after a reboot (bare metal) is still the one
# mounted, whatever is or isn't at the configured device now.
#
#   format-data.sh <device>
#
# CREW_BOX_ETC moves /etc/crew-box, and CREW_BOX_DEVICE_WAIT the 90 s
# this waits for the device, for the control plane's tests.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. "${CREW_BOX_ETC:-/etc/crew-box}/lib.sh"

dev=$1
label=crew-data
wait=${CREW_BOX_DEVICE_WAIT:-90}

# Crew's already, on any disk under any name: a scan of every block
# device, not udev's links, which may not be there this early.
labelled() { [ -n "$(blkid -c /dev/null -t "LABEL=$label" -o device 2>/dev/null || true)" ]; }

i=0
while :; do
  if labelled; then exit 0; fi
  if [ -b "$dev" ]; then break; fi
  i=$((i + 1))
  [ "$i" -lt "$wait" ] || fail "there's no data disk at $dev, and no disk is labelled $label"
  sleep 1
done

# Anything on it (a filesystem, a partition table, a RAID member) is
# someone's, and Crew leaves it alone.
if found=$(blkid -p -o export "$dev" 2>/dev/null); then
  kind=$(printf '%s\n' "$found" | sed -n -e 's/^TYPE=//p' -e 's/^PTTYPE=//p' | head -n 1)
  fail "the data disk $dev isn't empty (${kind:-something is on it}) and isn't Crew's; Crew won't format it"
fi

say "formatting the data disk $dev (XFS, reflink)"
# -K: no discard first, which can take minutes on a large SSD.
mkfs.xfs -q -K -L "$label" -m reflink=1 "$dev"
udevadm trigger --settle "$dev" 2>/dev/null || udevadm settle || true
