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
#   format-data.sh --partition <partition>
#
# --partition is a one-disk box's partition 10 of the OS disk, which a
# reinstall keeps. Its first boot (the Ignition's fresh-data marker)
# formats it whatever is on it, so a machine added again starts clean;
# nothing after that ever formats it.
#
# CREW_BOX_ETC moves /etc/crew-box, CREW_BOX_DEVICE_WAIT the 90 s this
# waits for the device, and CREW_BOX_FAKE_DEVICES takes a regular file
# for one, for the control plane's tests.
set -eu

# shellcheck source=SCRIPTDIR/lib.sh
. "${CREW_BOX_ETC:-/etc/crew-box}/lib.sh"

label=crew-data
wait=${CREW_BOX_DEVICE_WAIT:-90}
fresh=${CREW_BOX_ETC:-/etc/crew-box}/fresh-data

device() { [ -b "$1" ] || { [ -n "${CREW_BOX_FAKE_DEVICES:-}" ] && [ -f "$1" ]; }; }

# Crew's already, on any disk under any name: a scan of every block
# device, not udev's links, which may not be there this early.
labelled() { [ -n "$(blkid -c /dev/null -t "LABEL=$label" -o device 2>/dev/null || true)" ]; }

partition() {
  part=$1
  i=0
  until device "$part"; do
    i=$((i + 1))
    [ "$i" -lt "$wait" ] || fail "there's no data partition at $part; the box's Ignition adds it"
    sleep 1
  done

  if [ ! -e "$fresh" ]; then
    # A reprovision, or any boot after the first: the box's data is here,
    # or the box is gone. Formatting it would make a box with no identity
    # under the old one's name.
    [ "$(blkid -p -s LABEL -o value "$part" 2>/dev/null || true)" = "$label" ] ||
      fail "the data partition $part has no crew-data filesystem, so there's no box here to bring back; add the box again"
    exit 0
  fi

  mib=$(($(blockdev --getsize64 "$part") / 1048576))
  # Partition 10 starts at 32 GiB and ends 33 sectors short of the disk's.
  [ "$mib" -ge $((96 * 1024 - 1)) ] ||
    fail "the OS disk is under 128 GiB (its data partition is $mib MiB); add the box with a separate data disk"

  say "formatting the data partition $part (XFS, reflink)"
  wipefs -a "$part" >/dev/null || fail "couldn't wipe the data partition $part"
  # 16 MiB short of the partition's end, which is the disk's: a reinstall
  # zeroes the last 512 KiB.
  mkfs.xfs -q -K -f -L "$label" -m reflink=1 -d size=$((mib - 16))m "$part" ||
    fail "couldn't format the data partition $part"
  udevadm trigger --settle "$part" 2>/dev/null || udevadm settle || true
  rm -f "$fresh"
  # On disk before the box writes anything to the partition: back after
  # a power cut, the marker would format the box's data.
  sync
  exit 0
}

if [ "${1:-}" = --partition ]; then partition "$2"; fi

dev=$1

i=0
while :; do
  if labelled; then exit 0; fi
  if device "$dev"; then break; fi
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
