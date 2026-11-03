#!/bin/sh
# A stand-in for crew-guest, for the null driver (development and tests).
# It walks the guest API the way a job does: fetch the payload, listen,
# take a job, log a little, finish, and "power off" by exiting.
#
# When the JIT config names a fake GitHub (e2e/fake-github), the "runner"
# asks it for a job and reports it done, so GitHub's side of the job
# (assignment, in_progress, completed) happens as it would for real.
# Otherwise it takes a job at once.
#
#   CREW_GUEST_API  http://127.0.0.1:<port>
#   CREW_GUEST_TOKEN, CREW_GUEST_VM
#   FAKE_JOB_SECONDS  how long the "job" runs (default 1; a fake job's own wins)
#   FAKE_EXIT         the runner's exit code (default 0)
set -u
api="$CREW_GUEST_API"
auth="Authorization: Bearer $CREW_GUEST_TOKEN"
now_ms() { echo $(( $(date +%s) * 1000 )); }
post() { curl -fsS -m 10 -H "$auth" -H 'content-type: application/json' -d "$2" "$api$1" >/dev/null 2>&1; }
log() {
  printf '{"t":%s,"step_ref":"s1","text":"%s"}\n' "$(now_ms)" "$1" \
    | curl -fsS -m 10 -H "$auth" -H 'content-type: application/x-ndjson' --data-binary @- "$api/v1/log" >/dev/null 2>&1
}

i=0
until payload=$(curl -fsS -m 5 -H "$auth" "$api/v1/payload" 2>/dev/null); do
  i=$((i + 1)); [ "$i" -gt 300 ] && exit 1; sleep 0.2
done

fake=$(printf '%s' "$payload" | jq -r '.jit_config // empty' 2>/dev/null | base64 -d 2>/dev/null | jq -c '.fake // empty' 2>/dev/null)
seconds="${FAKE_JOB_SECONDS:-1}"
code="${FAKE_EXIT:-0}"

post /v1/state "{\"state\":\"runner_listening\",\"at\":$(now_ms),\"detail\":\"Listening for Jobs\"}"
sleep "${FAKE_IDLE_SECONDS:-0}"

if [ -n "$fake" ]; then
  gh=$(printf '%s' "$fake" | jq -r .api)
  name=$(printf '%s' "$fake" | jq -r .name)

  # Listen until GitHub assigns a job, or deletes the runner (410).
  while :; do
    status=$(curl -sS -m 30 -o job.json -w '%{http_code}' "$gh/__fake/runners/$name/job?wait=20" 2>/dev/null)
    case "$status" in
      200) break ;;
      410) exit 0 ;;
      *) sleep 0.5 ;;
    esac
  done

  job_seconds=$(jq -r '.seconds // empty' job.json)
  [ -n "$job_seconds" ] && seconds="$job_seconds"
  job_exit=$(jq -r '.exit // empty' job.json)
  [ -n "$job_exit" ] && code="$job_exit"
  job_name=$(jq -r '.name' job.json)
fi

post /v1/state "{\"state\":\"job_started\",\"at\":$(now_ms)}"
log "hello from the null driver"
log "\\u001b[32mgreen\\u001b[0m"
post /v1/steps "{\"steps\":[{\"ref\":\"s1\",\"name\":\"Run tests\",\"number\":1,\"status\":\"in_progress\",\"started_at\":$(now_ms)}]}"
sleep "$seconds"
[ -n "$fake" ] && log "finished ${job_name:-the job}"
post /v1/steps "{\"steps\":[{\"ref\":\"s1\",\"name\":\"Run tests\",\"number\":1,\"status\":\"completed\",\"conclusion\":\"$([ "$code" = 0 ] && echo success || echo failure)\",\"started_at\":$(now_ms),\"completed_at\":$(now_ms)}]}"

if [ -n "$fake" ]; then
  conclusion=$([ "$code" = 0 ] && echo success || echo failure)
  curl -fsS -m 10 -H 'content-type: application/json' -d "{\"conclusion\":\"$conclusion\"}" "$gh/__fake/runners/$name/done" >/dev/null 2>&1
fi

post /v1/state "{\"state\":\"job_finished\",\"at\":$(now_ms),\"detail\":\"exit_code=$code\"}"
exit 0
