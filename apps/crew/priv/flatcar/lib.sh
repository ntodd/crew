# Sourced by the Flatcar box's scripts in /etc/crew-box (docs/crew_spec.md
# §12.2). Flatcar mounts /etc noexec, so every one of them runs as
# `/bin/sh /etc/crew-box/<script>`, and this file is only ever read.
# shellcheck shell=sh

# Progress goes to the journal (stdout) and to every console the kernel
# has: /dev/console is only the last of them (under QEMU a VGA screen
# nobody watches), and the launchers follow the serial console for
# `crew-box: ` lines.
console() {
  echo "$*"
  [ -r /proc/consoles ] || return 0
  while read -r c _; do
    if [ -w "/dev/$c" ]; then echo "$*" > "/dev/$c" 2>/dev/null || true; fi
  done < /proc/consoles
}

say() { console "crew-box: $*"; }
fail() { say "$*"; exit 1; }
