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
# $T/fake/container  the control plane's container id (empty: none)
# $T/fake/image      the image it runs; compose up recreates it from .env
# $T/fake/published  refs a pull finds
# $T/fake/healthy    refs whose /healthz answers
# $T/fake/crashing   refs whose container keeps restarting
# $T/fake/labels     "<ref> <version>" for an image labelled other than its tag
# $T/fake/calls      what was asked of docker and the fakes

use_fakes() {
  DIR=$T/update
  CONF=$T/update.conf
  BIN=$T/bin/crew-update
  HEALTH_TIMEOUT=6
  sleep() { :; }
  backup() {
    echo "backup $data" >> "$T/fake/calls"
    echo "crew-data-$from-T.tgz"
  }
  restore() { echo "restore $1" >> "$T/fake/calls"; }
  refresh_self() { echo "refresh_self $1" >> "$T/fake/calls"; }
  docker() {
    echo "docker $*" >> "$T/fake/calls"
    case $1 in
      compose)
        shift 3
        case $1 in
          ps) cat "$T/fake/container" ;;
          stop | start | logs) : ;;
          up)
            sed -n 's/^CREW_IMAGE=//p' "$T/opt/.env" | tail -n 1 > "$T/fake/image"
            echo c1 > "$T/fake/container"
            ;;
        esac
        ;;
      inspect)
        case $3 in
          '{{.Config.Image}}') cat "$T/fake/image" ;;
          '{{.RestartCount}}') if grep -qxF "$(cat "$T/fake/image")" "$T/fake/crashing"; then echo 3; else echo 0; fi ;;
          '{{.State.Status}}'*) echo "running unless-stopped" ;;
          *Mounts*) echo crew-data ;;
        esac
        ;;
      image)
        ref=$5
        tag=${ref##*:}
        case $4 in
          *Labels*)
            label=$(sed -n "s|^$ref ||p" "$T/fake/labels")
            echo "${label:-${tag%-pg}}"
            ;;
          *Env*)
            echo PATH=/usr/bin
            case $tag in *-pg) echo CREW_DB=postgres ;; *) echo CREW_DB=sqlite ;; esac
            ;;
        esac
        ;;
      pull) grep -qxF "$3" "$T/fake/published" ;;
      exec) grep -qxF "$(cat "$T/fake/image")" "$T/fake/healthy" ;;
      *) return 1 ;;
    esac
  }
}

# A host running ghcr.io/ntodd/crew:0.2.0 (SQLite) from /opt/compose.yml.
host() {
  new_case
  printf 'COMPOSE_FILE=%s\nSERVICE=crew\n' "$T/opt/compose.yml" > "$T/update.conf"
  : > "$T/opt/compose.yml"
  printf 'OTHER=kept\nCREW_IMAGE=%s\n' "${1:-ghcr.io/ntodd/crew:0.2.0}" > "$T/opt/.env"
  echo c1 > "$T/fake/container"
  echo "${1:-ghcr.io/ntodd/crew:0.2.0}" > "$T/fake/image"
  for f in published healthy crashing labels calls; do : > "$T/fake/$f"; done
}
publish() { echo "$1" >> "$T/fake/published"; }
works() { echo "$1" >> "$T/fake/healthy"; }
ask() { printf '%s\n' "$1" > "$T/update/request/version"; }

run_update() {
  (. "$updater" && use_fakes && run) > "$T/out" 2>&1
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
check "no /healthz: restores the backup" asked "restore crew-data-0.2.0-T.tgz"
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
check "neither version comes up: says so" grep -q "neither did 0.2.0" "$T/update/status/state.json"

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
