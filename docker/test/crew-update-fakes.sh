# The fakes docker/test/crew-update-test.sh runs docker/crew-update
# against: docker, and the backup, restore and self-refresh that are
# nothing but docker runs. Each run is its own sh, which sources the
# updater, then this, then calls use_fakes and run, so a fake can signal
# the run by its $$. T is the case's directory:
#
#   $T/fake/container  the control plane's container id (empty: none)
#   $T/fake/image      the image it runs; compose up recreates it from .env
#   $T/fake/running    "running" or "stopped"
#   $T/fake/published  refs a pull finds
#   $T/fake/healthy    refs whose /healthz answers
#   $T/fake/crashing   refs whose container keeps restarting
#   $T/fake/labels     "<ref> <version>" for an image labelled other than its tag
#   $T/fake/calls      what was asked of docker and the fakes
#   $T/fake/inject     a fault to inject, once:
#     backup-fails       the backup writes part of its file, then fails
#     backup-signal      the backup writes part of its file, then the run gets SIGTERM
#     env-rename-fails   the new .env can't be renamed into place (disk full),
#                        after the old one is set aside
#     up-signal          compose up starts the new image, then the run gets SIGTERM
#     up-kill            compose up starts the new image, then the run is
#                        SIGKILLed: no trap runs
#     up-removes-backup  compose up starts the new image, which deletes
#                        the backup (real backups only)
#     up-corrupts-backup compose up starts the new image, which garbles
#                        the backup (real backups only)
#
# With $T/fake/real-backup, the updater's own backup() and restore() run:
# docker run runs their scripts here, with /data as $T/volume (the
# crew-data volume) and /backup as the updater's backups/, and an image
# listed in $T/fake/migrates writes "migrated by <ref>" to the volume's
# marker when it starts. date ticks a second on every call, so anything
# that reads the clock twice sees two times.
#
# shellcheck shell=sh disable=SC2034,SC2154,SC2329

# fault NAME: NAME is the injected fault; it's used up.
fault() {
  if [ "$(cat "$T/fake/inject" 2> /dev/null)" = "$1" ]; then
    rm -f "$T/fake/inject"
    return 0
  fi
  return 1
}

use_fakes() {
  DIR=$T/update
  CONF=$T/update.conf
  BIN=$T/bin/crew-update
  HEALTH_TIMEOUT=6
  sleep() { :; }
  date() {
    tick=$(($(cat "$T/fake/clock" 2> /dev/null || echo 0) + 1))
    echo "$tick" > "$T/fake/clock"
    s=$(printf '%02d' $((tick % 60)))
    case "$*" in
      *%Y%m%dT%H%M%SZ*) echo "20261104T1000${s}Z" ;;
      *) echo "2026-11-04T10:00:${s}Z" ;;
    esac
  }
  if [ ! -e "$T/fake/real-backup" ]; then
    backup() {
      echo "backup $data $backup_name" >> "$T/fake/calls"
      echo partial > "$DIR/backups/$backup_name"
      if fault backup-fails; then return 1; fi
      if fault backup-signal; then kill -TERM $$; fi
      return 0
    }
    restore() { echo "restore $1" >> "$T/fake/calls"; }
  fi
  refresh_self() { echo "refresh_self $1" >> "$T/fake/calls"; }
  mv() {
    if [ "${3:-}" = "$T/opt/.env" ]; then
      case $2 in
        *.crew-update.*)
          if fault env-rename-fails; then
            echo "mv: $3: No space left on device" >&2
            return 1
          fi
          ;;
      esac
    fi
    command mv "$@"
  }
  docker() {
    echo "docker $*" >> "$T/fake/calls"
    case $1 in
      compose)
        shift 3
        case $1 in
          ps) cat "$T/fake/container" ;;
          stop) echo stopped > "$T/fake/running" ;;
          start) echo running > "$T/fake/running" ;;
          logs) : ;;
          up)
            sed -n 's/^CREW_IMAGE=//p' "$T/opt/.env" 2> /dev/null | tail -n 1 > "$T/fake/image"
            echo c1 > "$T/fake/container"
            echo running > "$T/fake/running"
            if grep -qxF "$(cat "$T/fake/image")" "$T/fake/migrates" 2> /dev/null; then
              echo "migrated by $(cat "$T/fake/image")" > "$T/volume/marker"
            fi
            if fault up-removes-backup; then rm -f "$DIR"/backups/crew-data-*; fi
            if fault up-corrupts-backup; then
              for b in "$DIR"/backups/crew-data-*.tgz; do echo garbage > "$b"; done
            fi
            if fault up-signal; then kill -TERM $$; fi
            if fault up-kill; then kill -KILL $$; fi
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
      run) fake_run "$@" ;;
      exec)
        [ "$(cat "$T/fake/running")" = running ] &&
          grep -qxF "$(cat "$T/fake/image")" "$T/fake/healthy"
        ;;
      *) return 1 ;;
    esac
  }
}

# docker run, for the updater's own backup and restore: their sh or tar
# entrypoint runs here, with the mounts' container paths in the script
# and arguments rewritten to where they are on this side.
fake_run() {
  shift
  entry="" host_data="" host_backup=""
  while [ $# -gt 0 ]; do
    case $1 in
      --rm) shift ;;
      --network | --user) shift 2 ;;
      --entrypoint)
        entry=$2
        shift 2
        ;;
      -v)
        src=${2%%:*} rest=${2#*:}
        case ${rest%%:*} in
          /data) if [ "$src" = crew-data ]; then host_data=$T/volume; else host_data=$src; fi ;;
          /backup) host_backup=$src ;;
        esac
        shift 2
        ;;
      *) break ;;
    esac
  done
  shift
  here() { printf '%s' "$1" | sed -e "s|/backup|$host_backup|g" -e "s|/data|$host_data|g"; }
  case $entry in
    sh)
      [ "$1" = -c ] || return 125
      script=$(here "$2")
      shift 2
      command sh -c "$script" "$@"
      ;;
    tar)
      n=$#
      for a in "$@"; do set -- "$@" "$(here "$a")"; done
      shift "$n"
      command tar "$@"
      ;;
    *) return 125 ;;
  esac
}
