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

# one_line <value> <extended regex>: the whole value is one line the
# pattern matches. grep matches line by line, so a value with a newline
# could pass on one good line: anything but the characters a version, a
# SHA-256, a nonce or base64 needs is refused before grep sees it (a
# newline among them).
one_line() {
  case "$1" in "" | *[!0-9A-Za-z.+/=-]*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eqx "$2"
}

# A release version, as CI tags them (CrewProtocol's): 1.2.3 or
# 1.2.3-rc.1. Never a path: no slash, and not `.` or `..`.
release_version() {
  case "$1" in */*) return 1 ;; esac
  one_line "$1" '[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-[0-9A-Za-z.]{1,32})?'
}

# exact_link <path>: sets $link to the link's target exactly. $(readlink)
# would drop trailing newlines, and a target of "1.2.3\n" isn't 1.2.3.
# shellcheck disable=SC2034 # $link is for the scripts that source this
exact_link() {
  link=""
  [ -L "$1" ] || return 1
  # -n: the target alone, without a newline of readlink's own.
  _out=$(readlink -n "$1" && echo x) || return 1
  link=${_out%x}
}

# root_release <root dir> <version>: <root dir>/<version> is a release
# root installed: a version's name, a directory and not a link, owned by
# whoever runs this (root on a box). Never anything the agent wrote.
root_release() {
  release_version "$2" || return 1
  [ -d "$1/$2" ] && [ ! -L "$1/$2" ] || return 1
  [ -n "$(find "$1/$2" -maxdepth 0 -type d -user "$(id -u)" 2>/dev/null)" ]
}

# check_release <name> <file> <version> <target> <sha256> <signature> <key.pem> <workdir>
# Succeeds when the file matches the SHA-256 and the ed25519 signature,
# over CrewProtocol.Auth.release_message/3's bytes, verifies against the
# key; otherwise says why in $why.
# shellcheck disable=SC2034 # $why is for the scripts that source this
check_release() {
  if [ "$(openssl dgst -sha256 -r "$2" | cut -d' ' -f1)" != "$5" ]; then
    why="the $1 doesn't match its SHA-256"
    return 1
  fi
  printf 'crew-release-v1\n%s\n%s\n%s' "$3" "$4" "$5" > "$8/$1.msg"
  if ! printf '%s' "$6" | openssl base64 -d -A > "$8/$1.sig" 2>/dev/null; then
    why="the $1's signature isn't base64"
    return 1
  fi
  if ! openssl pkeyutl -verify -pubin -inkey "$7" -rawin \
    -in "$8/$1.msg" -sigfile "$8/$1.sig" >/dev/null 2>&1; then
    why="the $1's signature doesn't verify against the release key"
    return 1
  fi
}

# crew-vmctl's units (native/crew-vmctl/etc/systemd), in every release.
root_units="crew-vmctl.socket crew-vmctl@.service crew-net.service crew-net-site4.service crew-net-site4.timer"

# root_half <release> <out>: what root runs, copied out of an unpacked
# agent tarball: crew-vmctl, jailer and Firecracker, the ruleset, and
# crew-vmctl's units pointed at /srv/crew/root/current. Fails, saying why
# in $why, when the release lacks any of it or a unit would run anything
# from the agent's directory.
# shellcheck disable=SC2034 # $why is for the scripts that source this
root_half() {
  for f in bin/crew_agent bin/crew-vmctl bin/jailer bin/firecracker; do
    if [ ! -x "$1/$f" ]; then
      why="the release has no $f"
      return 1
    fi
  done
  for f in etc/nft.conf etc/connlimit.rules; do
    if [ ! -f "$1/$f" ]; then
      why="the release has no $f"
      return 1
    fi
  done
  for u in $root_units; do
    if [ ! -f "$1/etc/systemd/$u" ]; then
      why="the release has no etc/systemd/$u"
      return 1
    fi
  done
  mkdir -p "$2/bin" "$2/etc/systemd"
  for b in crew-vmctl jailer firecracker; do
    cp "$1/bin/$b" "$2/bin/$b"
    chmod 0755 "$2/bin/$b"
  done
  cp "$1/etc/nft.conf" "$1/etc/connlimit.rules" "$2/etc/"
  for u in $root_units; do
    sed 's|/srv/crew/agent/current/bin/|/srv/crew/root/current/bin/|g' "$1/etc/systemd/$u" > "$2/etc/systemd/$u"
    if grep -q '/srv/crew/agent/' "$2/etc/systemd/$u"; then
      why="the release's $u takes something from the agent's directory, which root mustn't"
      return 1
    fi
  done
}

# relink <dir> <name> <target>: points <dir>/<name> at <target> with a new
# link renamed over the old one, so it always exists.
relink() {
  ln -sfn "$3" "$1/.$2.new"
  if ! mv -Tf "$1/.$2.new" "$1/$2" 2>/dev/null; then
    # BSD mv (the control plane's tests on a Mac) has no -T.
    rm -f "$1/$2"
    mv -f "$1/.$2.new" "$1/$2"
  fi
}
