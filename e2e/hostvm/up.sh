#!/bin/bash
# Development only: a Flatcar host VM with nested virtualization on this
# Mac (an M3 or later, macOS 15 or later), booted by native/hostvm-dev, for
# the Firecracker driver's real-KVM tests. Its state is in tmp/hostvm; it
# answers as core@<address> with tmp/hostvm/id_ed25519 (the address is
# printed in tmp/hostvm/serial.log). The first boot stages the Ignition as
# the mac-vm launcher does (spec §12.3): the image's own kernel, an ISO.
#
#   make -C native hostvm-dev && e2e/hostvm/up.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$root/native/hostvm-dev/hostvm-dev"
mkdir -p "$root/tmp/hostvm/images"
cd "$root/tmp/hostvm"

# Flatcar stable, pinned with the digests from the release's signed
# DIGESTS files (as Foreman's mac.sh pins them).
version=4757.2.3
image_sha512=5fdbb01d9d9706e7d93b22f619148723d6e88b300d241c2773ff34c17b93b81965798d29a5b6138a2a7197a8fd7b027d5093b458cacf90330360816c8a0b08e4
kernel_sha512=e9d852a45c4953123f513589f0c6b22abd3fbd58354875884fa03bc73d0be85b884cfcadb03646dc66b4b8ad9d710a2830cceee4f3b14712163fa56115f772b2
fetch() {
  if [ ! -f "images/$1" ] || [ "$(shasum -a 512 "images/$1" | cut -d' ' -f1)" != "$2" ]; then
    curl -fsSL -o "images/$1.part" "https://stable.release.flatcar-linux.net/arm64-usr/$version/$1"
    [ "$(shasum -a 512 "images/$1.part" | cut -d' ' -f1)" = "$2" ] || { rm -f "images/$1.part"; echo "$1: bad digest" >&2; exit 1; }
    mv "images/$1.part" "images/$1"
  fi
}
fetch flatcar_production_image.bin.bz2 "$image_sha512"
fetch flatcar_production_image.vmlinuz "$kernel_sha512"
verity=6ae5c5ebc899cb7e26ff0cf052d73929ebb0340d53d537c96a4957eafa5184f4
usr_a=7130c94a-213a-4e5a-8e26-6cce9662f132
mac=52:54:00:c7:e0:01

[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C crew-hostvm-dev -f id_ed25519
if [ ! -f os.img ]; then
  rm -rf cfg && mkdir cfg
  key=$(cat id_ed25519.pub)
  cat > cfg/config.ign <<IGN
{"ignition":{"version":"3.4.0"},"passwd":{"users":[{"name":"core","sshAuthorizedKeys":["$key"]}]}}
IGN
  cat > cfg/prep.sh <<'PREP'
#!/bin/sh
set -eu
flatcar-reset --ignition-file /run/crewcfg/config.ign
printf 'set linux_console="console=hvc0"\n' >> /oem/grub.cfg
sync
echo "crew-box: config staged"
PREP
  bunzip2 -c images/flatcar_production_image.bin.bz2 | dd of=os.img.raw bs=1048576 conv=sparse 2>/dev/null
  dd if=os.img.raw of=os.img.part bs=1048576 conv=sparse 2>/dev/null && rm -f os.img.raw
  truncate -s 40g os.img.part
  rm -f cfg.iso && hdiutil makehybrid -quiet -iso -joliet -default-volume-name CRWCFG -o cfg.iso cfg
  cpio -o -H newc < /dev/null > empty.cpio 2>/dev/null
  cmd="rootflags=rw mount.usrflags=ro consoleblank=0 root=LABEL=ROOT console=hvc0"
  cmd="$cmd mount.usr=/dev/mapper/usr verity.usr=PARTUUID=$usr_a verity.usrhash=$verity"
  cmd="$cmd systemd.mount-extra=LABEL=CRWCFG:/run/crewcfg:iso9660:ro \"systemd.run=/usr/bin/sh /run/crewcfg/prep.sh\""
  cmd="$cmd systemd.run_success_action=poweroff systemd.run_failure_action=poweroff"
  rm -f prep.log
  "$bin" -disk os.img.part -iso cfg.iso -serial prep.log -kernel images/flatcar_production_image.vmlinuz \
    -initrd empty.cpio -cmdline "$cmd" -cpus 2 -memory 2048
  grep -aq 'crew-box: config staged' prep.log || { tail -30 prep.log; exit 1; }
  mv os.img.part os.img
  [ -f data.img ] || truncate -s 100g data.img
fi
rm -f serial.log
exec "$bin" -disk os.img -disk data.img -serial serial.log -efi-vars efi-vars -cpus 8 -memory 16384 -nested -mac "$mac"
