#!/bin/sh
# Tests docker/crew-update's decisions without root or Docker: which
# requests it takes, how it compares versions, and what it does when the
# new version comes up healthy, doesn't, or can't be pulled. It sources
# the updater (CREW_UPDATE_SOURCED=1) and swaps docker, and the backup,
# restore and self-refresh that are nothing but docker runs, for fakes
# that record what they were asked.
#
#   docker/test/crew-update-test.sh
#
# What it can't reach (the backup's tar, the systemd units, a real pull
# and recreate) needs a host with Docker; docs/releasing.md says how to
# try an update before a release.
#
# The fakes replace the updater's functions and set its variables after
# it's sourced, which ShellCheck can't follow.
# shellcheck disable=SC1090,SC2016,SC2034,SC2154,SC2329
set -u

here=$(cd "$(dirname "$0")" && pwd)
updater=${CREW_UPDATE:-$here/../crew-update}
CREW_UPDATE_SOURCED=1
export CREW_UPDATE_SOURCED

pass=0 fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok    %s\n' "$1"
}
not_ok() {
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi
}
# check DESCRIPTION COMMAND...: passes when the command succeeds.
check() {
  desc=$1
  shift
  if "$@"; then ok "$desc"; else not_ok "$desc"; fi
}
# check_not DESCRIPTION COMMAND...: passes when the command fails.
check_not() {
  desc=$1
  shift
  if "$@"; then not_ok "$desc"; else ok "$desc"; fi
}
# equals DESCRIPTION EXPECTED ACTUAL
equals() {
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$2], got [$3]"; fi
}

# lib FUNCTION ARGS...: one of the updater's functions, in a subshell.
lib() { (. "$updater" && "$@"); }

nl='
'

# -- versions --------------------------------------------------------------------

for v in 0.1.0 1.2.3 10.20.30 9999.0.1 0.0.0; do
  check "is_version $v" lib is_version "$v"
done
for v in "" 1.2 1.2.3.4 v1.2.3 1.2.3-rc.1 " 1.2.3" "1.2.3 " 01.2.3 1.02.3 10000.0.0 \
  "1.2.3${nl}1.2.4" "garbage${nl}1.2.3" -1.2.3 1..3 ../1.2.3 "1.2.3;reboot" '$(id)'; do
  check_not "is_version refuses [$v]" lib is_version "$v"
done

check "1.2.4 is newer than 1.2.3" lib newer 1.2.4 1.2.3
check "1.10.0 is newer than 1.9.9 (not as text)" lib newer 1.10.0 1.9.9
check "2.0.0 is newer than 1.99.99" lib newer 2.0.0 1.99.99
check "0.3.0 is newer than 0.2.10" lib newer 0.3.0 0.2.10
check_not "1.2.3 isn't newer than itself" lib newer 1.2.3 1.2.3
check_not "1.2.2 isn't newer than 1.2.3" lib newer 1.2.2 1.2.3
check_not "1.9.9 isn't newer than 1.10.0" lib newer 1.9.9 1.10.0
check_not "a non-version is never newer" lib newer 9.9.9-rc.1 1.2.3

equals "repo_of a tagged ref" ghcr.io/ntodd/crew "$(lib repo_of ghcr.io/ntodd/crew:0.2.0)"
equals "repo_of a registry with a port" localhost:5000/crew "$(lib repo_of localhost:5000/crew:0.2.0)"
equals "repo_of an untagged ref with a port" localhost:5000/crew "$(lib repo_of localhost:5000/crew)"
equals "repo_of a ref with a digest" ghcr.io/ntodd/crew "$(lib repo_of ghcr.io/ntodd/crew:0.2.0@sha256:abc)"

# -- the request -------------------------------------------------------------------

T=""
new_case() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/crew-update-test.XXXXXX")
  mkdir -p "$T/update/request" "$T/update/status" "$T/update/backups" "$T/opt" "$T/bin" "$T/fake"
}
take() { (. "$updater" && DIR=$T/update && take_request); }
request_left() { find "$T/update/request" -mindepth 1 | wc -l | tr -d ' '; }

new_case
printf '1.2.3\n' > "$T/update/request/version"
equals "takes a version" 1.2.3 "$(take)"
equals "and empties the request directory" 0 "$(request_left)"

new_case
printf '1.2.3\r\n' > "$T/update/request/version"
equals "drops a CR" 1.2.3 "$(take)"

new_case
printf '1.2.3\nrm -rf /\n' > "$T/update/request/version"
equals "reads only the first line" 1.2.3 "$(take)"

new_case
printf '%0100d' 0 > "$T/update/request/version"
equals "reads at most 32 bytes" 32 "$(take | wc -c | tr -d ' ')"

new_case
printf '9.9.9\n' > "$T/secret"
ln -s "$T/secret" "$T/update/request/version"
equals "never reads through a symlink" "" "$(take)"
check "and leaves the symlink's target alone" test -f "$T/secret"
equals "and removes the symlink" 0 "$(request_left)"

new_case
mkdir "$T/update/request/version"
equals "a directory is no request" "" "$(take)"

new_case
mkfifo "$T/update/request/version"
take > "$T/out" &
pid=$!
waited=0
while kill -0 "$pid" 2> /dev/null && [ $waited -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "$pid" 2> /dev/null; then
  kill "$pid"
  not_ok "a FIFO is no request, and doesn't block"
else
  equals "a FIFO is no request, and doesn't block" "" "$(cat "$T/out")"
fi

new_case
printf '1.2.3\n' > "$T/update/request/version"
printf 'x\n' > "$T/update/request/other"
mkdir -p "$T/update/request/sub/dir"
take > /dev/null
equals "anything else in the request directory goes too" 0 "$(request_left)"

new_case
equals "no request, no version" "" "$(take)"

# -- a run, against a fake docker ------------------------------------------------
#
# docker/test/crew-update-fakes.sh says what the fakes read and record.

# A host running ghcr.io/ntodd/crew:0.2.0 (SQLite) from /opt/compose.yml.
host() {
  new_case
  printf 'COMPOSE_FILE=%s\nSERVICE=crew\n' "$T/opt/compose.yml" > "$T/update.conf"
  : > "$T/opt/compose.yml"
  printf 'OTHER=kept\nCREW_IMAGE=%s\n' "${1:-ghcr.io/ntodd/crew:0.2.0}" > "$T/opt/.env"
  echo c1 > "$T/fake/container"
  echo "${1:-ghcr.io/ntodd/crew:0.2.0}" > "$T/fake/image"
  echo running > "$T/fake/running"
  for f in published healthy crashing labels calls; do : > "$T/fake/$f"; done
}
publish() { echo "$1" >> "$T/fake/published"; }
works() { echo "$1" >> "$T/fake/healthy"; }
ask() { printf '%s\n' "$1" > "$T/update/request/version"; }

# Each run is its own sh, so an injected fault can signal it.
run_update() {
  T=$T sh -c '. "$1" && . "$2" && use_fakes && run' crew-update "$updater" "$here/crew-update-fakes.sh" \
    > "$T/out" 2>&1
  echo $? > "$T/status"
}

field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$T/update/status/state.json" 2> /dev/null; }
asked() { grep -q -- "$1" "$T/fake/calls"; }
env_image() { sed -n 's/^CREW_IMAGE=//p' "$T/opt/.env"; }

host
run_update
equals "no request: exits quietly" 0 "$(cat "$T/status")"
check_not "no request: no state written" test -f "$T/update/status/state.json"
check "no request: says the updater is installed" test -f "$T/update/status/updater"

host
ask latest
run_update
equals "not a version: fails" failed "$(field state)"
equals "not a version: says so" "The request wasn't a version." "$(field message)"
check_not "not a version: nothing pulled" asked "docker pull"

host
ask 0.2.0
run_update
equals "the running version: fails" failed "$(field state)"
equals "the running version: says why" "0.2.0 isn't newer than 0.2.0; nothing changed." "$(field message)"
check_not "the running version: nothing pulled" asked "docker pull"

host
ask 0.1.9
publish ghcr.io/ntodd/crew:0.1.9
run_update
equals "a downgrade: fails" failed "$(field state)"
check_not "a downgrade: nothing pulled" asked "docker pull"
equals "a downgrade: the image stays pinned" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"

host ghcr.io/ntodd/crew:latest
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
echo "ghcr.io/ntodd/crew:latest" > "$T/fake/labels"
run_update
equals "an unlabelled running image: fails" failed "$(field state)"
check_not "an unlabelled running image: nothing pulled" asked "docker pull"

host
ask 0.3.0
run_update
equals "not published: fails" failed "$(field state)"
equals "not published: says so" "Couldn't pull ghcr.io/ntodd/crew:0.3.0; nothing changed." "$(field message)"
check_not "not published: nothing stopped" asked "compose -f .* stop"

host
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
echo "ghcr.io/ntodd/crew:0.3.0 0.2.9" > "$T/fake/labels"
run_update
equals "a pulled image that isn't the version: fails" failed "$(field state)"
check_not "a pulled image that isn't the version: nothing stopped" asked "compose -f .* stop"
equals "a pulled image that isn't the version: the image stays pinned" \
  ghcr.io/ntodd/crew:0.2.0 "$(env_image)"

host
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
works ghcr.io/ntodd/crew:0.3.0
run_update
equals "a healthy update: succeeds" succeeded "$(field state)"
equals "a healthy update: from" 0.2.0 "$(field from)"
equals "a healthy update: to" 0.3.0 "$(field to)"
equals "a healthy update: pins the new image" ghcr.io/ntodd/crew:0.3.0 "$(env_image)"
check "a healthy update: keeps the rest of .env" grep -qx OTHER=kept "$T/opt/.env"
check "a healthy update: backs up the data volume first" asked "backup crew-data"
check "a healthy update: takes the new image's updater" asked "refresh_self ghcr.io/ntodd/crew:0.3.0"
check_not "a healthy update: restores nothing" asked "restore"
equals "a healthy update: exits 0" 0 "$(cat "$T/status")"

host
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
works ghcr.io/ntodd/crew:0.2.0
run_update
equals "no /healthz: rolls back" rolled_back "$(field state)"
equals "no /healthz: the previous image is pinned again" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
equals "no /healthz: and runs" ghcr.io/ntodd/crew:0.2.0 "$(cat "$T/fake/image")"
check "no /healthz: restores the backup" asked "restore crew-data-0.2.0-"
check_not "no /healthz: keeps this updater" asked "refresh_self"
equals "no /healthz: exits 1" 1 "$(cat "$T/status")"

host
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
echo ghcr.io/ntodd/crew:0.3.0 >> "$T/fake/crashing"
works ghcr.io/ntodd/crew:0.3.0
works ghcr.io/ntodd/crew:0.2.0
run_update
equals "a crash loop: rolls back, healthz or not" rolled_back "$(field state)"

host
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0
run_update
equals "neither version comes up: fails" failed "$(field state)"
check "neither version comes up: says so" grep -q "0.2.0 didn.t come back up healthy either" "$T/update/status/state.json"

host ghcr.io/ntodd/crew:0.2.0-pg
ask 0.3.0
publish ghcr.io/ntodd/crew:0.3.0-pg
works ghcr.io/ntodd/crew:0.3.0-pg
run_update
equals "Postgres: updates to the -pg image" ghcr.io/ntodd/crew:0.3.0-pg "$(env_image)"
equals "Postgres: succeeds" succeeded "$(field state)"
check_not "Postgres: no volume backup (the database is the provider's)" asked "backup"

host localhost:5000/crew:0.2.0
ask 0.3.0
publish localhost:5000/crew:0.3.0
works localhost:5000/crew:0.3.0
run_update
equals "a registry with a port: same repository" localhost:5000/crew:0.3.0 "$(env_image)"

host
printf '0.3.0\nghcr.io/evil/crew:9.9.9\n' > "$T/update/request/version"
publish ghcr.io/ntodd/crew:0.3.0
works ghcr.io/ntodd/crew:0.3.0
run_update
equals "a request can't name a repository" ghcr.io/ntodd/crew:0.3.0 "$(env_image)"

host
echo "" > "$T/fake/container"
ask 0.3.0
run_update
equals "no container: fails" failed "$(field state)"

# -- failures once the control plane is stopped ----------------------------------
#
# From stopping the control plane until the new version answers, any
# failure or signal starts the previous version again, with its .env and,
# once the new version has started, its data. A run killed outright is
# put right by the next.

running() { echo "$(cat "$T/fake/running") $(cat "$T/fake/image")"; }
run_state_left() { test -e "$T/update/run.state"; }
partial_backups() { find "$T/update/backups" -name 'crew-data-*' | wc -l | tr -d ' '; }
strays() { find "$T/opt" -name '.env.*' | wc -l | tr -d ' '; }
an_update() {
  host
  ask 0.3.0
  publish ghcr.io/ntodd/crew:0.3.0
  works ghcr.io/ntodd/crew:0.2.0
  works ghcr.io/ntodd/crew:0.3.0
  if [ -n "${1:-}" ]; then echo "$1" > "$T/fake/inject"; fi
}

an_update backup-fails
run_update
equals "the backup fails: fails" failed "$(field state)"
equals "the backup fails: says so" "The backup failed; 0.2.0 is running again and nothing changed." "$(field message)"
equals "the backup fails: the previous version runs" "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
equals "the backup fails: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
equals "the backup fails: the partial backup is gone" 0 "$(partial_backups)"
check_not "the backup fails: nothing left to recover" run_state_left

an_update backup-signal
run_update
equals "a signal during the backup: fails" failed "$(field state)"
check "a signal during the backup: says it was interrupted" grep -q "interrupted" "$T/update/status/state.json"
equals "a signal during the backup: the previous version runs" "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
equals "a signal during the backup: the partial backup is gone" 0 "$(partial_backups)"
check_not "a signal during the backup: nothing left to recover" run_state_left
check_not "a signal during the backup: exits non-zero" test "$(cat "$T/status")" = 0

if [ "$(id -u)" != 0 ]; then
  # The new .env can't be written at all (as with a full disk); root
  # ignores the mode, so this one only runs as a user.
  an_update
  chmod 0555 "$T/opt"
  run_update
  chmod 0755 "$T/opt"
  equals "the new .env can't be written: fails" failed "$(field state)"
  equals "the new .env can't be written: the previous version runs" \
    "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
  equals "the new .env can't be written: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
  check "the new .env can't be written: the backup is kept" test "$(partial_backups)" = 1
  check_not "the new .env can't be written: nothing left to recover" run_state_left
fi

an_update env-rename-fails
run_update
equals "the new .env can't be renamed into place: fails" failed "$(field state)"
equals "the new .env can't be renamed into place: the previous version runs" \
  "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
equals "the new .env can't be renamed into place: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
check "the new .env can't be renamed into place: with its other lines" grep -qx OTHER=kept "$T/opt/.env"
equals "the new .env can't be renamed into place: no stray files" 0 "$(strays)"
check_not "the new .env can't be renamed into place: no restore (0.3.0 never ran)" asked "restore"

an_update up-signal
run_update
equals "a signal while 0.3.0 starts: rolls back" rolled_back "$(field state)"
equals "a signal while 0.3.0 starts: the previous version runs" \
  "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
equals "a signal while 0.3.0 starts: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
check "a signal while 0.3.0 starts: restores the backup" asked "restore crew-data-0.2.0-"
check_not "a signal while 0.3.0 starts: nothing left to recover" run_state_left

an_update up-kill
run_update
equals "killed while 0.3.0 starts: 0.3.0 is left running" "running ghcr.io/ntodd/crew:0.3.0" "$(running)"
check "killed while 0.3.0 starts: the run's state is left" run_state_left
run_update
equals "killed while 0.3.0 starts: the next run rolls back" rolled_back "$(field state)"
check "killed while 0.3.0 starts: and says the last one was interrupted" \
  grep -q "interrupted" "$T/update/status/state.json"
equals "killed while 0.3.0 starts: the previous version runs" \
  "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
equals "killed while 0.3.0 starts: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
check "killed while 0.3.0 starts: restores the backup" asked "restore crew-data-0.2.0-"
check_not "killed while 0.3.0 starts: nothing left to recover" run_state_left

an_update
run_update
equals "a clean update leaves nothing to recover: succeeds" succeeded "$(field state)"
check_not "a clean update leaves nothing to recover: no run state" run_state_left
equals "a clean update leaves nothing to recover: no stray files" 0 "$(strays)"

# -- real backups ------------------------------------------------------------------
#
# The updater's own backup() and restore(), run here against a directory
# standing in for the volume, with a clock that ticks on every read.

real_update() {
  an_update "${1:-}"
  touch "$T/fake/real-backup"
  echo ghcr.io/ntodd/crew:0.3.0 > "$T/fake/migrates"
  : > "$T/fake/healthy"
  works ghcr.io/ntodd/crew:0.2.0
  mkdir -p "$T/volume/images/x" "$T/volume/logs"
  echo "at 0.2.0" > "$T/volume/marker"
  echo "a log" > "$T/volume/logs/one"
  echo "a rootfs" > "$T/volume/images/x/rootfs"
}
marker() { cat "$T/volume/marker" 2> /dev/null; }
backups() { find "$T/update/backups" -name 'crew-data-*' -exec basename {} \; | sort | tr '\n' ' '; }

real_update
run_update
equals "a real backup across a clock tick: rolls back" rolled_back "$(field state)"
equals "a real backup across a clock tick: the data is as it was" "at 0.2.0" "$(marker)"
check "a real backup across a clock tick: with the logs" test -f "$T/volume/logs/one"
check "a real backup across a clock tick: and the images left alone" test -f "$T/volume/images/x/rootfs"
equals "a real backup across a clock tick: the previous version runs" \
  "running ghcr.io/ntodd/crew:0.2.0" "$(running)"
case $(backups) in
  "crew-data-0.2.0-"*".tgz ") ok "a real backup across a clock tick: one backup, whole" ;;
  *) not_ok "a real backup across a clock tick: one backup, whole" "got [$(backups)]" ;;
esac

real_update
works ghcr.io/ntodd/crew:0.3.0
run_update
equals "an update with a real backup: succeeds" succeeded "$(field state)"
backup=$(find "$T/update/backups" -name 'crew-data-*.tgz' | head -n 1)
check "an update with a real backup: the backup has the data" sh -c 'tar -tzf "$1" | grep -qx ./marker' sh "$backup"
check_not "an update with a real backup: and not the images" sh -c 'tar -tzf "$1" | grep -q "^\./images"' sh "$backup"

real_update up-removes-backup
run_update
equals "the backup's gone when it's needed: fails" failed "$(field state)"
check "the backup's gone when it's needed: says it can't be read" grep -q "can't be read" "$T/update/status/state.json"
equals "the backup's gone when it's needed: the data is left as it was" \
  "migrated by ghcr.io/ntodd/crew:0.3.0" "$(marker)"
check "the backup's gone when it's needed: logs and all" test -f "$T/volume/logs/one"
equals "the backup's gone when it's needed: nothing is started on it" \
  "stopped ghcr.io/ntodd/crew:0.3.0" "$(running)"
equals "the backup's gone when it's needed: .env as it was" ghcr.io/ntodd/crew:0.2.0 "$(env_image)"
check_not "the backup's gone when it's needed: nothing left to recover" run_state_left

real_update up-corrupts-backup
run_update
equals "a garbled backup: fails" failed "$(field state)"
check "a garbled backup: says it can't be read" grep -q "can't be read" "$T/update/status/state.json"
equals "a garbled backup: the data is left as it was" "migrated by ghcr.io/ntodd/crew:0.3.0" "$(marker)"
check "a garbled backup: logs and all" test -f "$T/volume/logs/one"

real_update
rm -rf "$T/volume"
run_update
equals "a backup that can't be made: fails" "The backup failed; 0.2.0 is running again and nothing changed." \
  "$(field message)"
equals "a backup that can't be made: no partial file" "" "$(backups)"
equals "a backup that can't be made: the previous version runs" \
  "running ghcr.io/ntodd/crew:0.2.0" "$(running)"

# -- backups ---------------------------------------------------------------------

new_case
for i in 1 2 3 4 5; do
  touch -t "20260101000$i" "$T/update/backups/crew-data-0.$i.0-T.tgz"
done
(. "$updater" && DIR=$T/update && prune_backups)
equals "keeps the three newest backups" \
  "crew-data-0.3.0-T.tgz crew-data-0.4.0-T.tgz crew-data-0.5.0-T.tgz" \
  "$(cd "$T/update/backups" && echo crew-data-*)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
