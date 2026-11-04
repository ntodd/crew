#!/bin/sh
# Formats a Flatcar box's data disk (docs/crew_spec.md §12.2, §12.4), from
# crew-format-data.service before srv-crew.mount on every boot. It only
# ever formats an empty disk: one with no filesystem and no partition
# table, while no disk carries Crew's label. srv-crew.mount mounts the
# disk by that label, so a disk that comes back under another name after
# a reboot (bare metal) is still the one mounted.
#
#   format-data.sh <device>
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. /etc/crew-box/lib.sh

dev=$1
label=crew-data

# Already Crew's: this disk, or any other (a scan, not udev's links,
# which may not be there this early).
if [ "$(blkid -p -s LABEL -o value "$dev" 2>/dev/null || true)" = "$label" ] ||
  [ -n "$(blkid -c /dev/null -t "LABEL=$label" -o device 2>/dev/null || true)" ]; then
  exit 0
fi

[ -b "$dev" ] || fail "there's no data disk at $dev"

# Anything on it (a filesystem, a partition table, a RAID member) is
# someone's, and Crew leaves it alone.
if found=$(blkid -p -o export "$dev" 2>/dev/null); then
  kind=$(printf '%s\n' "$found" | sed -n -e 's/^TYPE=//p' -e 's/^PTTYPE=//p' | head -n 1)
  fail "the data disk $dev isn't empty (${kind:-something is on it}) and isn't Crew's; Crew won't format it"
fi

say "formatting the data disk $dev (XFS, reflink)"
mkfs.xfs -q -L "$label" -m reflink=1 "$dev"
udevadm trigger --settle "$dev" 2>/dev/null || udevadm settle || true
