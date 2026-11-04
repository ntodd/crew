#!/bin/sh
# Runs a Crew box on this Linux machine as a VM (docs/crew_spec.md §12.3,
# linux-vm): Flatcar Container Linux under QEMU with KVM, run by systemd.
# The box sets itself up on its first boot and enrolls with the control
# plane; Flatcar keeps itself up to date after that, and the box's job VMs
# run inside it, apart from this machine.
#
#   curl -fsSL __CREW_URL__/agent/linux-vm.sh | sudo sh -s -- --token cj_...
#
#   --cpus N        virtual CPUs (default: half this machine's)
#   --memory GiB    memory (default: half this machine's, at most 16)
#   --disk GiB      the OS disk (default 12)
#   --data GiB      the data disk: images, job VMs, the cache (default 200,
#                   at least 100)
#   --ssh-port N    where `crew-box ssh` reaches the box, on 127.0.0.1
#                   (default 2222)
#
# Both disks are sparse files: they only take what the box uses. Needs
# systemd and KVM with nested virtualization on. On Debian and Ubuntu it
# installs QEMU, the UEFI firmware and bzip2 if they're missing.
#
# Running it again updates the launcher and keeps the box and its disks;
# it needs no token. --cpus and --memory then apply from the box's next
# start. Afterwards, crew-box manages the box:
#
#   crew-box status | start | stop | restart | ssh | logs
#   crew-box reimage <ignition>    a fresh OS disk, for recovery
#   crew-box uninstall --yes
#
# QEMU runs as the crew-box user, sandboxed by systemd, with user-mode
# networking: the box reaches the network through this machine, and
# nothing on this machine's network changes.
set -eu

CREW_URL="__CREW_URL__"

# Flatcar for the first boot (images/flatcar/VERSION); the box updates
# itself after that. The digests are from the release's signed DIGESTS.
FLATCAR_VERSION="__FLATCAR_VERSION__"
FLATCAR_IMAGE_SHA512_AMD64="__FLATCAR_IMAGE_SHA512_AMD64__"
FLATCAR_IMAGE_SHA512_ARM64="__FLATCAR_IMAGE_SHA512_ARM64__"

# The machine's own paths sit under CREW_BOX_ROOT, which only the control
# plane's tests set.
ROOT="${CREW_BOX_ROOT:-}"
DIR="${CREW_BOX_DIR:-$ROOT/var/lib/crew-box}"
UNIT="${CREW_BOX_UNIT:-crew-box}"
USER_NAME=crew-box
SELF=$ROOT/usr/local/sbin/$UNIT

say() { echo "crew-box: $*"; }
fail() { echo "crew-box: $*" >&2; exit 1; }

# So a Ctrl-C runs the cleanup (an EXIT trap) too; dash skips it otherwise.
trap 'exit 130' INT TERM HUP

conf() { sed -n "s/^$1=//p" "$DIR/box.conf" 2>/dev/null | tail -1; }

# Prints the box's `crew-box: ` lines from its serial console as they
# come, until one matches the pattern, for up to 10 minutes.
follow() {
  i=0
  seen=0
  while [ $i -lt 600 ]; do
    if [ -f "$DIR/serial.log" ]; then
      lines=$(tr -d '\r' < "$DIR/serial.log" | grep -a -c '^crew-box: ' || true)
      if [ "$lines" -gt "$seen" ]; then
        tr -d '\r' < "$DIR/serial.log" | grep -a '^crew-box: ' | tail -n +"$((seen + 1))"
        seen=$lines
      fi
      if tr -d '\r' < "$DIR/serial.log" | grep -aqE "^crew-box: ($1)"; then return 0; fi
    fi
    if ! systemctl is-active --quiet "$UNIT"; then
      journalctl -u "$UNIT" -n 20 --no-pager >&2 || true
      fail "the box's VM stopped"
    fi
    i=$((i + 2))
    sleep 2
  done
  tail -n 40 "$DIR/serial.log" >&2 || true
  fail "the box didn't finish within 10 minutes; it keeps trying. Watch it with: crew-box logs"
}

# The image Flatcar boots first, checked against its pinned digest.
fetch_flatcar() {
  images="$DIR/images/$FLATCAR_VERSION-$1"
  mkdir -p "$images"
  image="$images/flatcar_production_image.bin.bz2"
  if [ ! -f "$image" ] || [ "$(sha512sum "$image" | cut -d' ' -f1)" != "$2" ]; then
    say "downloading Flatcar $FLATCAR_VERSION ($1)"
    curl -fsSL -o "$image.part" "https://stable.release.flatcar-linux.net/$1-usr/$FLATCAR_VERSION/flatcar_production_image.bin.bz2" </dev/null
    [ "$(sha512sum "$image.part" | cut -d' ' -f1)" = "$2" ] ||
      { rm -f "$image.part"; fail "Flatcar's image doesn't match its digest"; }
    mv -f "$image.part" "$image"
  fi
}

# The OS disk, from the image: most of it is empty partitions, so the
# zeros are skipped rather than written.
write_os_disk() {
  bunzip2 -c "$image" | dd of="$DIR/os.img.part" bs=1M iflag=fullblock conv=sparse status=none
  truncate -s "$1G" "$DIR/os.img.part"
}

# The Ignition with this launcher's own key for `crew-box ssh` added
# (Ignition merges the given config into this one).
with_launcher_key() {
  printf '{"ignition":{"version":"3.4.0","config":{"merge":[{"source":"data:;base64,%s"}]}},"passwd":{"users":[{"name":"core","sshAuthorizedKeys":["%s"]}]}}\n' \
    "$(base64 < "$1" | tr -d '\n')" "$(cat "$DIR/id_ed25519.pub")"
}

# -- the box's VM ------------------------------------------------------------

# What systemd runs: QEMU, booted from the box's OS disk, as crew-box.
run() {
  [ -f "$DIR/box.conf" ] || fail "no box here; set one up with the command from Add box"
  cpus=$(conf cpus)
  aio=$(conf aio)
  set -- \
    -name "$UNIT" -nodefaults -no-user-config -display none \
    -cpu host -smp "$cpus" -m "$(conf memory)G" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(conf firmware)" \
    -drive "if=pflash,format=raw,unit=1,file=$DIR/efi-vars.fd" \
    -object iothread,id=io0 -object iothread,id=io1 \
    -drive "if=none,id=os,file=$DIR/os.img,format=raw,cache=none,aio=$aio,discard=unmap,detect-zeroes=unmap" \
    -device "virtio-blk-pci,drive=os,iothread=io0,num-queues=$cpus" \
    -drive "if=none,id=data,file=$DIR/data.img,format=raw,cache=none,aio=$aio,discard=unmap,detect-zeroes=unmap" \
    -device "virtio-blk-pci,drive=data,iothread=io1,num-queues=$cpus,serial=crew-data" \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:$(conf ssh_port)-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$(conf mac)" \
    -device virtio-rng-pci \
    -device virtio-balloon-pci,free-page-reporting=on \
    -chardev "file,id=console,path=$DIR/serial.log" -serial chardev:console \
    -qmp "unix:$DIR/qmp.sock,server=on,wait=off" \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
  case "$(uname -m)" in
    x86_64) set -- -machine q35,accel=kvm "$@" ;;
    aarch64) set -- -machine virt,accel=kvm,gic-version=host "$@" ;;
  esac
  # The first-boot config, until the box has used it: a new box's holds
  # the join token and its Tailscale key.
  if [ -f "$DIR/config.ign" ] &&
    grep -aqsE 'crew-box: (enrolled|agent started)' "$DIR/serial.log" "$DIR/serial.log.1"; then
    rm -f "$DIR/config.ign"
  fi
  if [ -f "$DIR/config.ign" ]; then
    set -- "$@" -fw_cfg "name=opt/org.flatcar-linux/config,file=$DIR/config.ign"
  fi
  # Keep the previous boot's console for a look after a crash.
  [ ! -s "$DIR/serial.log" ] || mv -f "$DIR/serial.log" "$DIR/serial.log.1"
  exec "$(conf qemu)" "$@"
}

# Asks the box to shut down (its power button, through QEMU's monitor),
# and waits for QEMU to exit. systemd runs it as the unit's ExecStop.
powerdown() {
  pid=${MAINPID:-$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)}
  [ "${pid:-0}" -gt 0 ] && kill -0 "$pid" 2>/dev/null || return 0
  perl -MIO::Socket::UNIX -e '
    my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or exit 0;
    print $s qq({"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n);
    sleep 1;' "$DIR/qmp.sock" 2>/dev/null || true
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 100 ]; do
    sleep 1
    i=$((i + 1))
  done
}

status() {
  if ! [ -f "$DIR/box.conf" ]; then
    echo "no box"
    return 1
  fi
  echo "box:     $(conf name)"
  echo "size:    $(conf cpus) CPUs, $(conf memory) GiB"
  echo "disks:   OS $(du -h "$DIR/os.img" | cut -f1) of $(conf disk) GiB, data $(du -h "$DIR/data.img" | cut -f1) of $(conf data) GiB"
  echo "systemd: $(systemctl is-active "$UNIT" 2>/dev/null || true) ($UNIT.service)"
  echo "ssh:     crew-box ssh (127.0.0.1:$(conf ssh_port))"
}

ssh_box() {
  exec ssh -i "$DIR/id_ed25519" -p "$(conf ssh_port)" -o UserKnownHostsFile="$DIR/known_hosts" \
    -o StrictHostKeyChecking=accept-new core@127.0.0.1 "$@"
}

# A fresh OS disk from the release's first-boot Flatcar, booted with the
# given Ignition (the box page's reprovision one): for recovery (§12.1).
# The data disk, and with it the agent, its identity and the tailnet
# node, stays as it is.
reimage() {
  [ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"
  [ -f "$DIR/box.conf" ] || fail "no box here"
  [ -n "${1:-}" ] && [ -f "$1" ] || fail "usage: crew-box reimage <ignition file> (the box page has one)"
  grep -q '"ignition"' "$1" || fail "$1 isn't an Ignition config"
  case "$(conf arch)" in
    arm64) sha=$FLATCAR_IMAGE_SHA512_ARM64 ;;
    *) sha=$FLATCAR_IMAGE_SHA512_AMD64 ;;
  esac
  fetch_flatcar "$(conf arch)" "$sha"
  say "stopping the box"
  systemctl stop "$UNIT"
  say "writing a fresh OS disk ($(conf disk) GiB); the data disk stays as it is"
  write_os_disk "$(conf disk)"
  mv -f "$DIR/os.img.part" "$DIR/os.img"
  rm -rf "$DIR/images"
  cp "$(conf firmware_vars)" "$DIR/efi-vars.fd"
  with_launcher_key "$1" > "$DIR/config.ign"
  chmod 0600 "$DIR/config.ign"
  rm -f "$DIR/serial.log" "$DIR/serial.log.1"
  chown -R "$USER_NAME:$USER_NAME" "$DIR"
  systemctl start "$UNIT"
  follow 'enrolled|agent started|there.s no agent|the agent|the data disk'
  say "reimaged $(conf name) with Flatcar $FLATCAR_VERSION; it updates itself from here"
}

uninstall() {
  [ "${1:-}" = --yes ] || fail "this deletes the box's disks and everything on them; run: crew-box uninstall --yes (and revoke the box in Crew)"
  systemctl disable --now "$UNIT" 2>/dev/null || true
  rm -f "$ROOT/etc/systemd/system/$UNIT.service" "$SELF"
  systemctl daemon-reload
  rm -rf "$DIR"
  say "removed the box; revoke it on its page in Crew"
}

case "${1:-}" in
  run) run ;;
  powerdown) powerdown; exit ;;
  start) systemctl start "$UNIT"; exit ;;
  stop) systemctl stop "$UNIT"; exit ;;
  restart) systemctl restart "$UNIT"; exit ;;
  status) status; exit ;;
  ssh) shift; ssh_box "$@" ;;
  logs) exec tail -n 200 -F "$DIR/serial.log" ;;
  reimage) shift; reimage "$@"; exit ;;
  uninstall) shift; uninstall "$@"; exit ;;
esac

# Run as `curl ... | sh`, the shell reads this script from stdin as it
# goes, so nothing below may read stdin: every command that could gets
# /dev/null.

# -- install or update ---------------------------------------------------------

TOKEN=""
CPUS=""
MEMORY=""
DISK=12
DATA=200
SSH_PORT=2222

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --url) CREW_URL="$2"; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Linux ] || fail "this is for Linux; on a Mac use mac-vm.sh"
[ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
for n in CPUS MEMORY DISK DATA SSH_PORT; do
  eval "v=\${$n}"
  # shellcheck disable=SC2154
  case "$v" in *[!0-9]*) fail "--$(echo "$n" | tr '[:upper:]_' '[:lower:]-') takes a whole number" ;; esac
done
[ -c "$ROOT/dev/kvm" ] || fail "KVM isn't available (no /dev/kvm): turn on virtualization in the firmware, or load kvm_intel or kvm_amd"

# The box runs its job VMs with KVM itself, so this machine's KVM has to
# offer it nested virtualization.
case "$(uname -m)" in
  x86_64)
    arch=amd64 qemu=qemu-system-x86_64 packages="qemu-system-x86 ovmf"
    image_sha=$FLATCAR_IMAGE_SHA512_AMD64
    firmware_pairs="$ROOT/usr/share/OVMF/OVMF_CODE_4M.fd:$ROOT/usr/share/OVMF/OVMF_VARS_4M.fd
$ROOT/usr/share/OVMF/OVMF_CODE.fd:$ROOT/usr/share/OVMF/OVMF_VARS.fd
$ROOT/usr/share/edk2/ovmf/OVMF_CODE.fd:$ROOT/usr/share/edk2/ovmf/OVMF_VARS.fd
$ROOT/usr/share/edk2/x64/OVMF_CODE.4m.fd:$ROOT/usr/share/edk2/x64/OVMF_VARS.4m.fd
$ROOT/usr/share/qemu/ovmf-x86_64-code.bin:$ROOT/usr/share/qemu/ovmf-x86_64-vars.bin"
    nested=""
    for f in "$ROOT"/sys/module/kvm_intel/parameters/nested "$ROOT"/sys/module/kvm_amd/parameters/nested; do
      if [ -r "$f" ]; then
        case "$(cat "$f")" in Y | y | 1) nested=1 ;; esac
      fi
    done
    if [ -z "$nested" ]; then
      module=kvm_intel
      if grep -q AuthenticAMD "$ROOT/proc/cpuinfo"; then module=kvm_amd; fi
      fail "KVM's nested virtualization is off, and the box needs it for its job VMs. Turn it on with:
  echo 'options $module nested=1' | sudo tee /etc/modprobe.d/crew-kvm-nested.conf
  sudo modprobe -r $module && sudo modprobe $module    (or reboot)
then run this again"
    fi
    ;;
  aarch64)
    arch=arm64 qemu=qemu-system-aarch64 packages="qemu-system-arm qemu-efi-aarch64"
    image_sha=$FLATCAR_IMAGE_SHA512_ARM64
    firmware_pairs="$ROOT/usr/share/AAVMF/AAVMF_CODE.fd:$ROOT/usr/share/AAVMF/AAVMF_VARS.fd
$ROOT/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw:$ROOT/usr/share/edk2/aarch64/vars-template-pflash.raw
$ROOT/usr/share/edk2/aarch64/QEMU_CODE.fd:$ROOT/usr/share/edk2/aarch64/QEMU_VARS.fd"
    grep -q 'kvm-arm.mode=nested' "$ROOT/proc/cmdline" ||
      fail "KVM's nested virtualization is off, and the box needs it for its job VMs: boot with kvm-arm.mode=nested on the kernel command line, then run this again"
    ;;
  *) fail "unsupported architecture $(uname -m)" ;;
esac

find_firmware() {
  echo "$firmware_pairs" | while IFS=: read -r code vars; do
    if [ -f "$code" ] && [ -f "$vars" ]; then
      echo "$code:$vars"
      break
    fi
  done
}

new=""
[ -f "$DIR/box.conf" ] || new=1
# A new box, until it starts: a failure leaves nothing of it behind.
fresh_dir="" fresh_user="" fresh_unit="" fresh_self=""
work=$(mktemp -d)
# The EXIT trap runs it (SC2317 and SC2329 are the same check in older and newer ShellCheck).
# shellcheck disable=SC2317,SC2329
cleanup() {
  rm -rf "$work"
  [ -z "$fresh_unit" ] || { rm -f "$ROOT/etc/systemd/system/$UNIT.service"; systemctl daemon-reload; }
  [ -z "$fresh_self" ] || rm -f "$SELF"
  [ -z "$fresh_dir" ] || rm -rf "$DIR"
  [ -z "$fresh_user" ] || userdel "$USER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$new" ]; then
  [ -n "$TOKEN" ] || fail "--token is required (Add box in Crew makes one)"

  cores=$(nproc)
  mem_gib=$(($(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' "$ROOT/proc/meminfo") / 1048576))
  [ -n "$CPUS" ] || CPUS=$((cores / 2 > 2 ? cores / 2 : 2))
  [ -n "$MEMORY" ] || MEMORY=$((mem_gib / 2 > 16 ? 16 : (mem_gib / 2 < 4 ? 4 : mem_gib / 2)))
  [ "$CPUS" -le "$cores" ] || fail "--cpus $CPUS is more than this machine's $cores"
  [ "$MEMORY" -lt "$mem_gib" ] || fail "--memory $MEMORY GiB leaves nothing for this machine's $mem_gib GiB"
  [ "$DISK" -ge 8 ] || fail "--disk needs at least 8 GiB"
  [ "$DATA" -ge 100 ] || fail "--data needs at least 100 GiB"

  [ -e "$DIR" ] || fresh_dir=1
  [ -e "$ROOT/etc/systemd/system/$UNIT.service" ] || fresh_unit=1
  [ -e "$SELF" ] || fresh_self=1
  id "$USER_NAME" >/dev/null 2>&1 || fresh_user=1

  # A key of its own for `crew-box ssh`, and the box's MAC address.
  ssh-keygen -q -t ed25519 -N "" -C "crew-box@$(hostname)" -f "$work/id_ed25519" </dev/null
  mac=$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':' | sed 's/^/52:54:00/; s/:$//')

  # First, so a bad token fails before anything is downloaded.
  say "asking $CREW_URL for the box's first-boot config"
  code=$(curl -sS -D "$work/headers" -o "$work/config.ign" -w '%{http_code}' \
    -X POST "$CREW_URL/agent/flatcar/ignition" \
    --data-urlencode "join_token=$TOKEN" --data-urlencode "arch=$arch" \
    --data-urlencode "ssh_keys[]=$(cat "$work/id_ed25519.pub")" </dev/null) || fail "couldn't reach $CREW_URL"
  [ "$code" = 200 ] || fail "Crew said $code: $(cat "$work/config.ign")"
  name=$(tr -d '\r' < "$work/headers" | sed -n 's/^[Xx]-[Cc]rew-[Bb]ox: *//p' | tail -1)
  case "$name" in "" | *[!a-z0-9-]*) fail "Crew didn't name the box" ;; esac
fi

# bzip2 for Flatcar's image, which minimal systems (Ubuntu's cloud
# images) leave out.
packages="$packages bzip2"
if ! command -v "$qemu" >/dev/null 2>&1 || [ -z "$(find_firmware)" ] || ! command -v bunzip2 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    say "installing what the box needs ($packages)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $packages </dev/null >/dev/null
  else
    fail "install QEMU ($qemu), UEFI firmware for it and bzip2 first (on Fedora: qemu-kvm edk2-ovmf bzip2)"
  fi
fi
qemu_path=$(command -v "$qemu") || fail "$qemu isn't installed"
firmware=$(find_firmware)
[ -n "$firmware" ] || fail "no UEFI firmware for $qemu found"
firmware_code=${firmware%%:*}
firmware_vars=${firmware#*:}
for tool in curl bunzip2 sha512sum perl ssh-keygen setpriv base64; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

id "$USER_NAME" >/dev/null 2>&1 ||
  useradd --system --home-dir "$DIR" --shell /usr/sbin/nologin "$USER_NAME"
kvm_group=""
if getent group kvm >/dev/null 2>&1; then
  usermod -aG kvm "$USER_NAME"
  kvm_group="SupplementaryGroups=kvm"
fi
install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$DIR"

# io_uring where the kernel lets QEMU's user have it (kernel.io_uring_disabled
# can keep it from unprivileged users), with direct I/O on the filesystem
# the disks go on; threads otherwise.
aio=threads
probe="$DIR/.aio-probe"
truncate -s 1M "$probe"
chown "$USER_NAME" "$probe"
if printf 'quit\n' | timeout 30 setpriv --reuid="$USER_NAME" --regid="$USER_NAME" --clear-groups \
  "$qemu_path" -nodefaults -display none -machine none -S -monitor stdio \
  -drive "if=none,id=probe,file=$probe,format=raw,cache=none,aio=io_uring" >/dev/null 2>&1; then
  aio=io_uring
fi
rm -f "$probe"

say "installing $SELF"
curl -fsSL -o "$SELF.new" "$CREW_URL/agent/linux-vm.sh" </dev/null || fail "couldn't reach $CREW_URL"
chmod 0755 "$SELF.new"
mv -f "$SELF.new" "$SELF"

cat > "$ROOT/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Crew box (Flatcar VM)
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
$kvm_group
Environment=CREW_BOX_DIR=$DIR CREW_BOX_UNIT=$UNIT
ExecStart=$SELF run
ExecStop=$SELF powerdown
TimeoutStopSec=120
Restart=always
RestartSec=5
# QEMU needs KVM and the box's directory, and nothing else of this machine.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=false
DevicePolicy=closed
DeviceAllow=/dev/kvm rw
ReadWritePaths=$DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

if [ -z "$new" ]; then
  # An update: the box and its disks stay as they are. (To start over
  # with a new token: crew-box uninstall --yes, then this again.)
  { grep -v -e '^cpus=' -e '^memory=' -e '^qemu=' -e '^firmware=' -e '^firmware_vars=' -e '^aio=' "$DIR/box.conf"
    echo "cpus=${CPUS:-$(conf cpus)}"
    echo "memory=${MEMORY:-$(conf memory)}"
    echo "qemu=$qemu_path"
    echo "firmware=$firmware_code"
    echo "firmware_vars=$firmware_vars"
    echo "aio=$aio"; } > "$DIR/box.conf.new"
  mv -f "$DIR/box.conf.new" "$DIR/box.conf"
  chown "$USER_NAME:$USER_NAME" "$DIR/box.conf"
  systemctl enable "$UNIT" >/dev/null 2>&1
  systemctl start "$UNIT"
  [ -z "$CPUS$MEMORY" ] || say "the box gets $(conf cpus) CPUs and $(conf memory) GiB from its next start (crew-box restart)"
  say "updated; the box keeps its disks and enrollment"
  exit 0
fi

fetch_flatcar "$arch" "$image_sha"

say "writing the box's disks (OS $DISK GiB, data $DATA GiB, both sparse)"
write_os_disk "$DISK"
mv -f "$DIR/os.img.part" "$DIR/os.img"
truncate -s "${DATA}G" "$DIR/data.img"
rm -rf "$DIR/images"
cp "$firmware_vars" "$DIR/efi-vars.fd"
install -m 0600 "$work/config.ign" "$DIR/config.ign"
install -m 0600 "$work/id_ed25519" "$DIR/id_ed25519"
install -m 0644 "$work/id_ed25519.pub" "$DIR/id_ed25519.pub"

cat > "$DIR/box.conf" <<EOF
name=$name
arch=$arch
cpus=$CPUS
memory=$MEMORY
disk=$DISK
data=$DATA
mac=$mac
ssh_port=$SSH_PORT
qemu=$qemu_path
firmware=$firmware_code
firmware_vars=$firmware_vars
aio=$aio
flatcar=$FLATCAR_VERSION
EOF
chown -R "$USER_NAME:$USER_NAME" "$DIR"

# The box exists from here on, and keeps trying whatever happens next.
fresh_dir="" fresh_user="" fresh_unit="" fresh_self=""
say "starting the box ($CPUS CPUs, $MEMORY GiB); it sets itself up on its first boot"
systemctl enable "$UNIT" >/dev/null 2>&1
systemctl restart "$UNIT"

# Its first boot: Ignition, the data disk, the tailnet, the agent.
follow enrolled
# Spent: the token and the box's Tailscale key.
rm -f "$DIR/config.ign"
say "done: $name is on the Boxes page in Crew"
say "manage it with crew-box (status, stop, start, restart, ssh, logs, reimage, uninstall)"
