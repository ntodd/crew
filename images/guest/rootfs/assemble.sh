#!/bin/bash
# Makes rootfs.ext4 from the rootfs build's tar on stdin (docs/crew_spec.md
# §13.1): `mkfs.ext4 -L crewroot -O ^has_journal -d <tree>`, then
# `e2fsck -f`. Runs in the builder image:
#   /work   a Docker volume, for the unpacked tree (kept for inspection)
#   /out    where rootfs.ext4 goes
#
# The filesystem's UUID and hash seed come from SOURCE_DATE_EPOCH and the
# arch, and its timestamps from SOURCE_DATE_EPOCH, so they don't vary
# between builds of one commit.
set -euo pipefail

arch=${CREW_ARCH:?}
epoch=${SOURCE_DATE_EPOCH:?}
tree=/work/tree
img=/out/rootfs.ext4.part

t0=$(date +%s)
rm -rf "$tree" "$img"
mkdir -p "$tree"
tar -C "$tree" --numeric-owner --xattrs --xattrs-include='*' -xpf -
t1=$(date +%s)

# BuildKit bind-mounts these into every build step, so the build can't
# write them. crew-guest rewrites resolv.conf at boot (§13.2).
echo crew > "$tree/etc/hostname"
cat > "$tree/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 crew
::1 localhost ip6-localhost ip6-loopback
EOF
rm -f "$tree/etc/resolv.conf"
echo 'nameserver 10.199.0.1' > "$tree/etc/resolv.conf"
rm -f "$tree/.dockerenv"

for f in sbin/init opt/crew-guest/bin/crew_guest opt/crew/hooks/job-started.sh \
  etc/systemd/system/crew-guest.service home/runner/actions-runner/run.sh; do
  [ -e "$tree/$f" ] || { echo "assemble: the tree has no /$f" >&2; exit 1; }
done
ls "$tree"/usr/lib/modules/*/modules.dep >/dev/null

# Room for the tree, ext4's metadata and the first moments of boot; the
# VM's disk is bigger, and crew-guest grows the filesystem into it.
used=$(du -sm "$tree" | cut -f1)
size=$(( (used * 115 / 100 + 512 + 63) / 64 * 64 ))
uuid=$(printf 'crew-guest-rootfs %s %s' "$arch" "$epoch" | sha256sum |
  sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-a\4-\5/')

E2FSPROGS_FAKE_TIME=$epoch mkfs.ext4 -q -F -L crewroot -O ^has_journal \
  -U "$uuid" -E "hash_seed=$uuid,nodiscard" -d "$tree" "$img" "${size}M"
e2fsck -fn "$img" >/dev/null || { echo "assemble: e2fsck -f found problems" >&2; e2fsck -fn "$img" >&2; exit 1; }
t2=$(date +%s)

mv "$img" /out/rootfs.ext4
echo "assemble: rootfs.ext4 ${size} MiB (${used} MiB used), uuid $uuid;" \
  "unpack $((t1 - t0))s, mkfs and e2fsck $((t2 - t1))s"
