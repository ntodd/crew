#!/bin/sh
# Runs a Crew box on this Mac (docs/crew_spec.md §12.3, mac-vm): Flatcar
# Container Linux in a VM on Apple's hypervisor through vfkit, with nested
# virtualization for the box's own job VMs, started by launchd at boot
# whether or not anyone is logged in. The box sets itself up on its first
# boot and enrolls with the control plane.
#
#   curl -fsSL __CREW_URL__/agent/mac-vm.sh | sudo sh -s -- --token cj_...
#
#   --cpus N        virtual CPUs (default: half this Mac's cores)
#   --memory GiB    memory (default: half this Mac's, at most 16)
#   --disk GiB      the OS disk (default 12)
#   --data GiB      the data disk: images, job VMs, the cache (default 200,
#                   at least 100)
#   --role cache    a mac-vz box's cache VM instead (§12.3, §15.6), named
#                   cachevm: crew_cache for the box's job VMs, no nested
#                   virtualization, so any Apple silicon (default 2 CPUs,
#                   4 GiB, data 100 GiB, at least 20). install-macos.sh
#                   --cache-vm runs it with the box's join token; the
#                   cache's management token is left in cachevm/mgmt-token.
#
# Needs macOS 15 or later on an M3 or later (Apple's nested
# virtualization). Both disks are sparse files. Running it again updates
# the launcher and vfkit and keeps the boxes; it needs no token. --cpus
# and --memory then apply to the box named with --name (or the only one)
# from its next start. Afterwards, crew-box manages a box:
#
#   crew-box status | start | stop | restart | ssh | logs [name]
#   crew-box restart --role cache [--trigger FILE]   the cache VM (launchd's
#                                        com.crew.hostvm-restart, for the agent)
#   crew-box reimage <ignition> [name]   a fresh OS disk, for recovery
#   crew-box uninstall --yes [name]
#
# Everything is root's, in /Library/Application Support/Crew/hostvm. The
# VM sees nothing of the Mac's files and reaches the network through the
# Mac's NAT.
set -eu

CREW_URL="__CREW_URL__"

# Flatcar for the first boot (images/flatcar/VERSION); the box updates
# itself after that. The digests are from the release's signed DIGESTS.
FLATCAR_VERSION="__FLATCAR_VERSION__"
FLATCAR_IMAGE_SHA512_ARM64="__FLATCAR_IMAGE_SHA512_ARM64__"
FLATCAR_KERNEL_SHA512_ARM64="__FLATCAR_KERNEL_SHA512_ARM64__"
FLATCAR_VERITY_ARM64="__FLATCAR_VERITY_ARM64__"
# Every Flatcar image's USR-A partition, which the first boot runs from.
FLATCAR_USR_A="__FLATCAR_USR_A__"

# vfkit's release binary: universal, signed by Red Hat, with the
# virtualization entitlement.
VFKIT_VERSION="__VFKIT_VERSION__"
VFKIT_SHA256="__VFKIT_SHA256__"

# The Mac's own paths sit under CREW_BOX_ROOT, which only the control
# plane's tests set.
ROOT="${CREW_BOX_ROOT:-}"
HOSTVM="${CREW_HOSTVM_DIR:-$ROOT/Library/Application Support/Crew/hostvm}"
BIN="$HOSTVM/bin"
SELF="$BIN/crew-box"
LINK="$ROOT/usr/local/bin/crew-box"
LAUNCHD="$ROOT/Library/LaunchDaemons"

say() { echo "crew-box: $*"; }
fail() { echo "crew-box: $*" >&2; exit 1; }

# The box's disks hold its agent's key, and the install its join token:
# nothing here is for the Mac's other users.
umask 077
# So a Ctrl-C runs the cleanup (an EXIT trap) too.
trap 'exit 130' INT TERM HUP

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
sha512() { shasum -a 512 "$1" | cut -d' ' -f1; }

# -- one box -------------------------------------------------------------------

# Picks the box: the name given, or the only one.
pick() {
  name=${1:-}
  if [ -z "$name" ]; then
    set --
    for d in "$HOSTVM"/*/box.conf; do
      if [ -f "$d" ]; then set -- "$@" "$(basename "$(dirname "$d")")"; fi
    done
    [ $# -gt 0 ] || fail "there's no box on this Mac"
    [ $# -eq 1 ] || fail "there are several boxes here ($*); name one"
    name=$1
  fi
  case "$name" in "" | *[!a-z0-9-]*) fail "'$name' isn't a box name" ;; esac
  BOX="$HOSTVM/$name"
  LABEL="com.crew.hostvm.$name"
  PLIST="$LAUNCHD/$LABEL.plist"
  [ -f "$BOX/box.conf" ] || [ -n "${2:-}" ] || fail "there's no box named $name here"
}

conf() { sed -n "s/^$1=//p" "$BOX/box.conf" 2>/dev/null | tail -1; }

# The cache VM's boot ID, from crew_cache's GET /host; empty when it
# doesn't answer.
cache_boot() {
  ip=$(address)
  [ -n "$ip" ] && [ -s "$BOX/mgmt-token" ] || return 0
  curl -fsS --max-time 5 -H "authorization: Bearer $(cat "$BOX/mgmt-token")" "http://$ip:7780/host" </dev/null 2>/dev/null |
    sed -n 's/.*"boot_id":"\([0-9a-f-]*\)".*/\1/p' || true
}

# Picks the VM with a role (the cache VM).
pick_role() {
  for d in "$HOSTVM"/*/box.conf; do
    if [ -f "$d" ] && grep -qx "role=$1" "$d"; then
      pick "$(basename "$(dirname "$d")")"
      return 0
    fi
  done
  fail "there's no $1 VM on this Mac"
}

rest() { curl -fsS --max-time 10 --unix-socket "$BOX/rest.sock" "$@"; }

vm_state() { rest http://localhost/vm/state 2>/dev/null | sed -n 's/.*"state":"VirtualMachineState\([A-Za-z]*\)".*/\1/p'; }

loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }

# The address vmnet's DHCP server gave the box (it asks by MAC address):
# the lease with the latest expiry, which the file keeps as fixed-width hex.
address() {
  mac=$(conf mac | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
  awk -v hw="1,$mac" '
    /^[ \t]*ip_address=/ { sub(/.*ip_address=/, ""); ip = $0 }
    /^[ \t]*hw_address=/ { sub(/.*hw_address=/, ""); match_hw = ($0 == hw) }
    /^[ \t]*lease=/ { sub(/.*lease=/, ""); if (match_hw && $0 > best) { best = $0; found = ip } }
    END { if (found) print found }' "$ROOT/var/db/dhcpd_leases" 2>/dev/null || true
}

# What launchd runs: the VM, booted from its OS disk, with the data disk.
run() {
  pick "${1:-}"
  store="efi,variable-store=$BOX/efi-vars"
  [ -e "$BOX/efi-vars" ] || store="$store,create"
  # Keep the previous boot's console for a look after a crash.
  [ ! -s "$BOX/serial.log" ] || mv -f "$BOX/serial.log" "$BOX/serial.log.1"
  rm -f "$BOX/rest.sock"
  # Nested virtualization for a box's job VMs; the cache VM runs none.
  if [ "$(conf role)" = cache ]; then set --; else set -- --nested; fi
  exec "$BIN/vfkit" \
    --cpus "$(conf cpus)" --memory "$(($(conf memory) * 1024))" \
    --bootloader "$store" \
    --device "virtio-blk,path=$BOX/os.img" \
    --device "virtio-blk,path=$BOX/data.img" \
    --device "virtio-net,nat,mac=$(conf mac)" \
    --device "virtio-serial,logFilePath=$BOX/serial.log" \
    --device virtio-rng \
    --restful-uri "unix://$BOX/rest.sock" \
    "$@"
}

start() {
  loaded && return 0
  launchctl bootstrap system "$PLIST" </dev/null || fail "launchd wouldn't start the box ($PLIST)"
}

# Unloads the job: launchd sends vfkit SIGTERM, vfkit asks the box to
# power off and waits for it (the plist's ExitTimeOut). Asking the box
# first would race launchd, which starts vfkit again when it exits.
stop() {
  if loaded; then launchctl bootout "system/$LABEL" 2>/dev/null || true; fi
  i=0
  while { loaded || pgrep -f "vfkit.*$BOX/os.img" >/dev/null; } && [ $i -lt 140 ]; do
    sleep 0.5
    i=$((i + 1))
  done
}

status() {
  pick "${1:-}"
  echo "box:     $(conf name)"
  [ -z "$(conf role)" ] || echo "role:    $(conf role)"
  echo "size:    $(conf cpus) CPUs, $(conf memory) GiB"
  echo "disks:   OS $(du -h "$BOX/os.img" | cut -f1) of $(conf disk) GiB, data $(du -h "$BOX/data.img" | cut -f1) of $(conf data) GiB"
  if loaded; then echo "launchd: loaded ($LABEL)"; else echo "launchd: not loaded"; fi
  echo "vm:      $(vm_state || true)"
  ip=$(address)
  echo "address: ${ip:-unknown}"
}

ssh_box() {
  ip=$(address)
  [ -n "$ip" ] || fail "the box has no address yet"
  exec ssh -i "$BOX/id_ed25519" -o UserKnownHostsFile="$BOX/known_hosts" \
    -o StrictHostKeyChecking=accept-new "core@$ip" "$@"
}

# Prints the box's `crew-box: ` lines from its serial console as they
# come, until one matches the pattern, for up to 10 minutes.
follow() {
  i=0
  seen=0
  while [ $i -lt 600 ]; do
    if [ -f "$BOX/serial.log" ]; then
      lines=$(tr -d '\r' < "$BOX/serial.log" | grep -a -c '^crew-box: ' || true)
      if [ "$lines" -gt "$seen" ]; then
        tr -d '\r' < "$BOX/serial.log" | grep -a '^crew-box: ' | tail -n +"$((seen + 1))"
        seen=$lines
      fi
      if tr -d '\r' < "$BOX/serial.log" | grep -aqE "^crew-box: ($1)"; then return 0; fi
    fi
    i=$((i + 2))
    sleep 2
  done
  tail -n 40 "$BOX/serial.log" >&2 || true
  fail "the box didn't finish within 10 minutes; it keeps trying. Watch it with: crew-box logs $(conf name)"
}

# Flatcar's image and kernel, checked against their pinned digests.
fetch_flatcar() {
  images="$HOSTVM/images/$FLATCAR_VERSION-arm64"
  mkdir -p "$images"
  base="https://stable.release.flatcar-linux.net/arm64-usr/$FLATCAR_VERSION"
  for f in "flatcar_production_image.bin.bz2:$FLATCAR_IMAGE_SHA512_ARM64" \
    "flatcar_production_image.vmlinuz:$FLATCAR_KERNEL_SHA512_ARM64"; do
    file=${f%%:*} sha=${f#*:}
    if [ ! -f "$images/$file" ] || [ "$(sha512 "$images/$file")" != "$sha" ]; then
      say "downloading $file (Flatcar $FLATCAR_VERSION)"
      curl -fSL --progress-bar -o "$images/$file.part" "$base/$file" </dev/null
      [ "$(sha512 "$images/$file.part")" = "$sha" ] ||
        { rm -f "$images/$file.part"; fail "$file doesn't match its digest"; }
      mv -f "$images/$file.part" "$images/$file"
    fi
  done
}

# The OS disk from the image, in $BOX/os.img.part. Most of the image is
# empty partitions, so the zeros are skipped. APFS fills in much of a file
# written slowly from a pipe, holes and all, so it's copied once more,
# file to file, which keeps them (0.9 GB on disk rather than 5).
write_os_disk() {
  bunzip2 -c "$images/flatcar_production_image.bin.bz2" | dd of="$BOX/os.img.raw" bs=1048576 conv=sparse 2>/dev/null
  dd if="$BOX/os.img.raw" of="$BOX/os.img.part" bs=1048576 conv=sparse 2>/dev/null
  rm -f "$BOX/os.img.raw"
  truncate -s "$1g" "$BOX/os.img.part" 2>/dev/null || mkfile -n "$1g" "$BOX/os.img.part"
}

# The Ignition goes in the image's OEM partition, which is btrfs, so a
# Linux has to write it: the image's own kernel, started once without
# booting its usual way, with the config on an ISO. It stages it with
# flatcar-reset, sends the console to the virtio one, and powers off.
# Then the ISO is gone. $1 is the Ignition, $2 a scratch directory.
stage_ignition() {
  mkdir -p "$2/config"
  cp "$1" "$2/config/config.ign"
  cat > "$2/config/prep.sh" <<'EOF'
#!/bin/sh
set -eu
flatcar-reset --ignition-file /run/crewcfg/config.ign
printf 'set linux_console="console=hvc0"\n' >> /oem/grub.cfg
sync
echo "crew-box: config staged"
EOF
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name CRWCFG -o "$2/config.iso" "$2/config" </dev/null
  rm -rf "$2/config"
  cpio -o -H newc < /dev/null > "$2/empty.cpio" 2>/dev/null

  say "staging the config"
  cmdline="rootflags=rw mount.usrflags=ro consoleblank=0 root=LABEL=ROOT console=hvc0"
  cmdline="$cmdline mount.usr=/dev/mapper/usr verity.usr=PARTUUID=$FLATCAR_USR_A verity.usrhash=$FLATCAR_VERITY_ARM64"
  cmdline="$cmdline systemd.mount-extra=LABEL=CRWCFG:/run/crewcfg:iso9660:ro \"systemd.run=/usr/bin/sh /run/crewcfg/prep.sh\""
  cmdline="$cmdline systemd.run_success_action=poweroff systemd.run_failure_action=poweroff"
  "$BIN/vfkit" --cpus 2 --memory 2048 \
    --kernel "$images/flatcar_production_image.vmlinuz" --initrd "$2/empty.cpio" --kernel-cmdline "$cmdline" \
    --device "virtio-blk,path=$BOX/os.img.part" --device "virtio-blk,path=$2/config.iso,readonly" \
    --device virtio-net,nat --device "virtio-serial,logFilePath=$2/prep.log" --device virtio-rng \
    </dev/null > "$2/vfkit.log" 2>&1 &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 180 ]; then kill -9 "$pid"; break; fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  rm -f "$2/config.iso"
  if ! grep -aq 'crew-box: config staged' "$2/prep.log"; then
    tail -n 30 "$2/prep.log" >&2 || true
    rm -f "$BOX/os.img.part"
    fail "couldn't stage the first-boot config (the console's last lines are above)"
  fi
}

# The Ignition with this launcher's own key for `crew-box ssh` added
# (Ignition merges the given config into this one).
with_launcher_key() {
  printf '{"ignition":{"version":"3.4.0","config":{"merge":[{"source":"data:;base64,%s"}]}},"passwd":{"users":[{"name":"core","sshAuthorizedKeys":["%s"]}]}}\n' \
    "$(base64 < "$1" | tr -d '\n')" "$(cat "$BOX/id_ed25519.pub")"
}

# A fresh OS disk from the release's first-boot Flatcar, booted with the
# given Ignition (the box page's reprovision one): for recovery (§12.1).
# The data disk, and with it the agent, its identity and the tailnet
# node, stays as it is.
reimage() {
  [ -n "${1:-}" ] && [ -f "$1" ] || fail "usage: crew-box reimage <ignition file> [name] (the box page has one)"
  grep -q '"ignition"' "$1" || fail "$1 isn't an Ignition config"
  pick "${2:-}"
  fetch_flatcar
  work="$BOX/reimage"
  rm -rf "$work"
  mkdir -p "$work"
  with_launcher_key "$1" > "$work/config.ign"
  say "stopping the box"
  stop
  say "writing a fresh OS disk ($(conf disk) GiB); the data disk stays as it is"
  write_os_disk "$(conf disk)"
  stage_ignition "$work/config.ign" "$work"
  mv -f "$BOX/os.img.part" "$BOX/os.img"
  rm -rf "$work" "$HOSTVM/images"
  rm -f "$BOX/efi-vars" "$BOX/serial.log" "$BOX/serial.log.1"
  start
  if [ "$(conf role)" = cache ]; then
    follow 'cache ready|crew_cache didn.t|the cache.s management token'
  else
    follow 'enrolled|agent started|there.s no agent|the agent|the data disk'
  fi
  say "reimaged $(conf name) with Flatcar $FLATCAR_VERSION; it updates itself from here"
}

uninstall() {
  [ "${1:-}" = --yes ] || fail "this deletes the box's disks and everything on them; run: crew-box uninstall --yes [name] (and revoke the box in Crew)"
  pick "${2:-}"
  stop
  rm -f "$PLIST" "$HOSTVM/$name.conf"
  rm -rf "$BOX"
  if ! ls "$HOSTVM"/*/box.conf >/dev/null 2>&1; then
    rm -f "$LINK"
    rm -rf "$HOSTVM"
  fi
  say "removed $name; revoke it on its page in Crew"
}

as_root() { [ "$(id -u)" -eq 0 ] || fail "run this as root (sudo crew-box $*)"; }

case "${1:-}" in
  run) shift; run "$@" ;;
  start) shift; as_root start; pick "${1:-}"; start; exit ;;
  stop) shift; as_root stop; pick "${1:-}"; stop; exit ;;
  restart)
    shift
    as_root restart
    if [ "${1:-}" = --role ]; then
      [ "${2:-}" = cache ] || fail "--role takes cache"
      shift 2
      # launchd runs this when the agent's request appears, and again when
      # it's taken away: only a request there restarts the VM, and only on
      # the boot it names (two requests for one boot restart it once).
      asked=""
      if [ "${1:-}" = --trigger ]; then
        [ -e "${2:-}" ] || exit 0
        asked=$(head -n 1 "$2" | tr -d '\r\n')
        rm -f "$2"
      fi
      pick_role cache
      if printf '%s\n' "$asked" | grep -Eqx '[0-9a-f-]{36}'; then
        # A boot it already restarted (a second request for it can come
        # while the new boot isn't answering yet), or one it has left.
        if [ "$(cat "$BOX/restarted-boot" 2>/dev/null || true)" = "$asked" ]; then
          say "the cache VM already restarted from boot $asked"
          exit 0
        fi
        current=$(cache_boot)
        if [ -n "$current" ] && [ "$current" != "$asked" ]; then
          say "the cache VM already restarted (it's on boot $current)"
          exit 0
        fi
        printf '%s\n' "$asked" > "$BOX/restarted-boot"
      fi
    else
      pick "${1:-}"
    fi
    stop
    start
    exit
    ;;
  status) shift; as_root status; status "$@"; exit ;;
  ssh) shift; as_root ssh; pick "${1:-}"; [ $# -eq 0 ] || shift; ssh_box "$@" ;;
  logs) shift; as_root logs; pick "${1:-}"; exec tail -n 200 -F "$BOX/serial.log" ;;
  reimage) shift; as_root reimage; reimage "$@"; exit ;;
  uninstall) shift; as_root uninstall; uninstall "$@"; exit ;;
esac

# Run as `curl ... | sh`, the shell reads this script from stdin as it
# goes, so nothing below may read stdin: every command that could gets
# /dev/null.

# -- install or update ---------------------------------------------------------

TOKEN=""
CPUS=""
MEMORY=""
DISK=12
DATA=""
NAME=""
ROLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --url) CREW_URL="$2"; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || fail "this is for macOS; on Linux use linux-vm.sh"
case "$ROLE" in "" | cache) ;; *) fail "--role takes cache (a mac-vz box's cache VM)" ;; esac
[ "$(id -u)" -eq 0 ] || fail "run this as root: curl ... | sudo sh -s -- --token ..."
for n in CPUS MEMORY DISK DATA; do
  eval "v=\${$n}"
  # shellcheck disable=SC2154
  case "$v" in *[!0-9]*) fail "--$(echo "$n" | tr '[:upper:]' '[:lower:]') takes a whole number" ;; esac
done

# Apple's hypervisor offers nested virtualization from macOS 15, on an M3
# or later; the box's job VMs need it. The cache VM runs no VMs.
major=$(sw_vers -productVersion | cut -d. -f1)
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
generation=$(printf '%s\n' "$chip" | sed -n 's/^Apple M\([0-9][0-9]*\).*/\1/p')
if [ -z "$ROLE" ] && { [ "$major" -lt 15 ] || [ -z "$generation" ] || [ "$generation" -lt 3 ]; }; then
  fail "a mac-vm box needs macOS 15 or later on an M3 or later, for nested virtualization (this is macOS $(sw_vers -productVersion) on ${chip:-an unknown chip}); a mac-vz box runs on any Apple silicon Mac"
fi
[ "$(uname -m)" = arm64 ] || fail "a mac-vm box needs Apple silicon"

# vfkit, this script as the command that manages the boxes (the control
# plane's current copy), and each box's launchd job.
install_launcher() {
  mkdir -p "$BIN"
  # Readable, so a mac-vz box's agent can read <name>.conf, each VM's
  # memory, off its capacity (§11.4); each VM's own directory is 0700.
  chmod 0755 "$HOSTVM" "$BIN"
  [ -d "$(dirname "$LINK")" ] || install -d -m 0755 "$(dirname "$LINK")"
  if [ ! -x "$BIN/vfkit" ] || [ "$(sha256 "$BIN/vfkit")" != "$VFKIT_SHA256" ]; then
    say "downloading vfkit $VFKIT_VERSION"
    curl -fsSL -o "$BIN/vfkit.new" "https://github.com/crc-org/vfkit/releases/download/$VFKIT_VERSION/vfkit" </dev/null
    [ "$(sha256 "$BIN/vfkit.new")" = "$VFKIT_SHA256" ] || { rm -f "$BIN/vfkit.new"; fail "vfkit doesn't match its digest"; }
    chmod 0755 "$BIN/vfkit.new"
    mv -f "$BIN/vfkit.new" "$BIN/vfkit"
  fi

  curl -fsSL -o "$SELF.new" "$CREW_URL/agent/mac-vm.sh" </dev/null || fail "couldn't reach $CREW_URL"
  chmod 0755 "$SELF.new"
  mv -f "$SELF.new" "$SELF"
  ln -sf "$SELF" "$LINK"

  # An if, not `[ ] &&`: with no box yet the glob stays as it is, and a
  # false test as the function's last status would end the install.
  for conf_file in "$HOSTVM"/*/box.conf; do
    if [ -f "$conf_file" ]; then write_plist "$(basename "$(dirname "$conf_file")")"; fi
  done
}

# What a mac-vz box's agent takes off its capacity (§11.4): this VM's
# memory, readable in hostvm/<name>.conf.
write_memory() {
  printf 'memory_mib=%s\n' "$(($(conf memory) * 1024))" > "$HOSTVM/$1.conf.new"
  chmod 0644 "$HOSTVM/$1.conf.new"
  mv -f "$HOSTVM/$1.conf.new" "$HOSTVM/$1.conf"
}

# A root LaunchDaemon per box (Foreman's plist, as a daemon): a CI box has
# to come back after a power cut with nobody logged in.
write_plist() {
  plist="$LAUNCHD/com.crew.hostvm.$1.plist"
  cat > "$plist.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.crew.hostvm.$1</string>
  <key>ProgramArguments</key>
  <array><string>$SELF</string><string>run</string><string>$1</string></array>
  <key>RunAtLoad</key><true/>
  <!-- A VM can't reboot itself on Apple's hypervisor: vfkit exits, and
       launchd starts it again. -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <!-- On SIGTERM (unload, shutdown) vfkit asks the box to power off. -->
  <key>ExitTimeOut</key><integer>60</integer>
  <!-- Builds run in the box: no background throttling. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOSTVM/$1/vfkit.log</string>
  <key>StandardErrorPath</key><string>$HOSTVM/$1/vfkit.log</string>
</dict>
</plist>
EOF
  chmod 0644 "$plist.new"
  chown root:wheel "$plist.new"
  mv -f "$plist.new" "$plist"
}

sleep_note() {
  if [ "$(pmset -g 2>/dev/null | awk '$1 == "sleep" { print $2 }')" != 0 ]; then
    say "this Mac sleeps, which pauses its boxes and their jobs; to keep it awake: sudo pmset -a sleep 0"
  fi
}

if [ -z "$TOKEN" ]; then
  # An update: the boxes and their disks stay as they are. (To start one
  # over with a new token: crew-box uninstall --yes <name>, then this
  # again.)
  ls "$HOSTVM"/*/box.conf >/dev/null 2>&1 || fail "--token is required (Add box in Crew makes one)"
  install_launcher
  if [ -n "$CPUS$MEMORY" ]; then
    pick "$NAME"
    { grep -v -e '^cpus=' -e '^memory=' "$BOX/box.conf"
      echo "cpus=${CPUS:-$(conf cpus)}"
      echo "memory=${MEMORY:-$(conf memory)}"; } > "$BOX/box.conf.new"
    mv -f "$BOX/box.conf.new" "$BOX/box.conf"
    write_memory "$name"
    say "$name gets $(conf cpus) CPUs and $(conf memory) GiB from its next start (sudo crew-box restart $name)"
  fi
  for conf_file in "$HOSTVM"/*/box.conf; do
    pick "$(basename "$(dirname "$conf_file")")"
    write_memory "$name"
    start
  done
  say "updated; the boxes keep their disks and enrollment"
  exit 0
fi

cores=$(sysctl -n hw.ncpu)
mem_gib=$(($(sysctl -n hw.memsize) / 1073741824))
if [ "$ROLE" = cache ]; then
  # crew_cache and its store: small, and on any Mac beside the box.
  [ -n "$CPUS" ] || CPUS=2
  [ -n "$MEMORY" ] || MEMORY=4
  [ -n "$DATA" ] || DATA=100
  [ "$DATA" -ge 20 ] || fail "--data needs at least 20 GiB for the cache"
else
  [ -n "$CPUS" ] || CPUS=$((cores / 2 > 2 ? cores / 2 : 2))
  [ -n "$MEMORY" ] || MEMORY=$((mem_gib / 2 > 16 ? 16 : (mem_gib / 2 < 4 ? 4 : mem_gib / 2)))
  [ -n "$DATA" ] || DATA=200
  [ "$DATA" -ge 100 ] || fail "--data needs at least 100 GiB"
fi
[ "$CPUS" -le "$cores" ] || fail "--cpus $CPUS is more than this Mac's $cores"
[ "$MEMORY" -lt "$mem_gib" ] || fail "--memory $MEMORY GiB leaves nothing for this Mac's $mem_gib GiB"
[ "$DISK" -ge 8 ] || fail "--disk needs at least 8 GiB"

# A new box. Until it starts, a failure leaves nothing behind.
fresh_hostvm=""
[ -e "$HOSTVM" ] || fresh_hostvm=1
work=$(mktemp -d)
BOX=""
# The EXIT trap runs it (SC2317 and SC2329 are the same check in older and newer ShellCheck).
# shellcheck disable=SC2317,SC2329
cleanup() {
  rm -rf "$work"
  if [ -n "$BOX" ]; then
    rm -f "$PLIST"
    rm -rf "$BOX"
  fi
  if [ -n "$fresh_hostvm" ]; then
    rm -f "$LINK"
    rm -rf "$HOSTVM"
  fi
}
trap cleanup EXIT

# A key of its own for `crew-box ssh`, and the box's MAC address.
ssh-keygen -q -t ed25519 -N "" -C "crew-box@$(hostname -s)" -f "$work/id_ed25519" </dev/null
mac=$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':' | sed 's/^/52:54:00/; s/:$//')

# First, so a bad token fails before anything is downloaded.
if [ "$ROLE" = cache ]; then
  say "asking $CREW_URL for the cache VM's first-boot config"
  endpoint="$CREW_URL/agent/flatcar/cachevm/ignition"
  set --
else
  say "asking $CREW_URL for the box's first-boot config"
  endpoint="$CREW_URL/agent/flatcar/ignition"
  set -- --data-urlencode "arch=arm64"
fi
code=$(curl -sS -D "$work/headers" -o "$work/config.ign" -w '%{http_code}' \
  -X POST "$endpoint" --data-urlencode "join_token=$TOKEN" "$@" \
  --data-urlencode "ssh_keys[]=$(cat "$work/id_ed25519.pub")" </dev/null) || fail "couldn't reach $CREW_URL"
[ "$code" = 200 ] || fail "Crew said $code: $(cat "$work/config.ign")"
# A response header's value (names are case-insensitive).
header() {
  tr -d '\r' < "$work/headers" |
    awk -v name="$1" 'tolower(substr($0, 1, length(name) + 1)) == tolower(name) ":" { sub(/^[^:]*: */, ""); v = $0 } END { print v }'
}
box_name=$(header X-Crew-Box)
case "$box_name" in "" | *[!a-z0-9-]*) fail "Crew didn't name the box" ;; esac
name=$box_name
if [ "$ROLE" = cache ]; then
  name=cachevm
  mgmt_token=$(header X-Crew-Cache-Token)
  case "$mgmt_token" in "" | *[!A-Za-z0-9_-]*) fail "Crew didn't give the cache a management token" ;; esac
  [ ! -e "$HOSTVM/$name" ] || fail "there's a cache VM here already; to start it over: sudo crew-box uninstall --yes $name"
fi
[ ! -e "$HOSTVM/$name" ] || fail "there's a box named $name here already; to start it over: sudo crew-box uninstall --yes $name"

pick "$name" new
mkdir -p "$BOX"
chmod 0700 "$BOX"
install -m 0600 "$work/id_ed25519" "$BOX/id_ed25519"
install -m 0644 "$work/id_ed25519.pub" "$BOX/id_ed25519.pub"
if [ "$ROLE" = cache ]; then printf '%s\n' "$mgmt_token" > "$BOX/mgmt-token"; fi

install_launcher
fetch_flatcar

say "writing the box's disks (OS $DISK GiB, data $DATA GiB, both sparse)"
write_os_disk "$DISK"
stage_ignition "$work/config.ign" "$work"
mv -f "$BOX/os.img.part" "$BOX/os.img"
truncate -s "${DATA}g" "$BOX/data.img" 2>/dev/null || mkfile -n "${DATA}g" "$BOX/data.img"
rm -rf "$HOSTVM/images"

cat > "$BOX/box.conf" <<EOF
name=$name
cpus=$CPUS
memory=$MEMORY
disk=$DISK
data=$DATA
mac=$mac
flatcar=$FLATCAR_VERSION
EOF
if [ "$ROLE" = cache ]; then echo "role=cache" >> "$BOX/box.conf"; fi
write_memory "$name"
write_plist "$name"

# The box exists from here on, and keeps trying whatever happens next.
trap 'rm -rf "$work"' EXIT
say "starting the box ($CPUS CPUs, $MEMORY GiB); it sets itself up on its first boot"
start

if [ "$ROLE" = cache ]; then
  # Its first boot: Ignition, the data disk, crew_cache.
  follow 'cache ready'
  say "done: $box_name's cache VM is up (crew-box status $name)"
  exit 0
fi

# Its first boot: Ignition, the data disk, the tailnet, the agent.
follow enrolled
say "done: $name is on the Boxes page in Crew"
say "manage it with crew-box (status, stop, start, restart, ssh, logs, reimage, uninstall)"
sleep_note
