#!/bin/sh
# A stand-in for crew-guest, for the null driver (development and tests).
# It walks the guest API the way a job does: fetch the payload, listen,
# take a job, log a little, finish, and "power off" by exiting.
#
#   CREW_GUEST_API  http://127.0.0.1:<port>
#   CREW_GUEST_TOKEN, CREW_GUEST_VM
#   FAKE_JOB_SECONDS  how long the "job" runs (default 1)
#   FAKE_EXIT         the runner's exit code (default 0)
set -u
api="$CREW_GUEST_API"
auth="Authorization: Bearer $CREW_GUEST_TOKEN"
now_ms() { echo $(( $(date +%s) * 1000 )); }
post() { curl -fsS -m 10 -H "$auth" -H 'content-type: application/json' -d "$2" "$api$1" >/dev/null 2>&1; }

i=0
until curl -fsS -m 5 -H "$auth" "$api/v1/payload" -o /dev/null 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 300 ] && exit 1; sleep 0.2
done

post /v1/state "{\"state\":\"runner_listening\",\"at\":$(now_ms),\"detail\":\"Listening for Jobs\"}"
sleep "${FAKE_IDLE_SECONDS:-0}"
post /v1/state "{\"state\":\"job_started\",\"at\":$(now_ms)}"
printf '{"t":%s,"step_ref":"s1","text":"hello from the null driver"}\n{"t":%s,"step_ref":"s1","text":"\\u001b[32mgreen\\u001b[0m"}\n' "$(now_ms)" "$(now_ms)" \
  | curl -fsS -m 10 -H "$auth" -H 'content-type: application/x-ndjson' --data-binary @- "$api/v1/log" >/dev/null 2>&1
post /v1/steps "{\"steps\":[{\"ref\":\"s1\",\"name\":\"Run tests\",\"number\":1,\"status\":\"in_progress\",\"started_at\":$(now_ms)}]}"
sleep "${FAKE_JOB_SECONDS:-1}"
post /v1/state "{\"state\":\"job_finished\",\"at\":$(now_ms),\"detail\":\"exit ${FAKE_EXIT:-0}\"}"
exit 0
