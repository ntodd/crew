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
  log_kind=$(jq -r '.log // empty' job.json)
  log_lines=$(jq -r '.log_lines // 0' job.json)
fi

post /v1/state "{\"state\":\"job_started\",\"at\":$(now_ms)}"
log "hello from the null driver"
log "\\u001b[32mgreen\\u001b[0m"

# A rich log (fake GitHub's `log: "rich"`): groups, colours, annotations
# and `log_lines` filler lines, posted in batches as crew-guest does.
if [ "${log_kind:-}" = rich ]; then
  t=$(now_ms)
  {
    printf '{"t":%s,"step_ref":"s1","text":"::group::Install dependencies"}\n' "$t"
    for i in 1 2 3 4 5; do printf '{"t":%s,"step_ref":"s1","text":"  fetched package %s"}\n' "$t" "$i"; done
    printf '{"t":%s,"step_ref":"s1","text":"::endgroup::"}\n' "$t"
    printf '{"t":%s,"step_ref":"s1","text":"\\u001b[32mgreen\\u001b[0m and \\u001b[1;31mbold red\\u001b[0m and \\u001b[38;5;214morange\\u001b[0m"}\n' "$t"
    printf '{"t":%s,"step_ref":"s1","text":"::warning file=lib/app.ex,line=3::Deprecated call"}\n' "$t"
    printf '{"t":%s,"step_ref":"s1","text":"<b>not bold</b> https://example.com/not-a-link"}\n' "$t"
    printf '{"t":%s,"step_ref":"s1","text":"a needle in the haystack"}\n' "$t"
    seq 1 "$log_lines" | awk -v t="$t" '{printf "{\"t\":%d,\"step_ref\":\"s1\",\"text\":\"filler line %d of the big log\"}\n", t, $1}'
    printf '{"t":%s,"step_ref":"s1","text":"::error file=test/app_test.exs,line=12::Expected 1, got 2"}\n' "$t"
  } > rich.ndjson
  split -l 4000 rich.ndjson rich.part.
  for part in rich.part.*; do
    curl -fsS -m 10 -H "$auth" -H 'content-type: application/x-ndjson' --data-binary @"$part" "$api/v1/log" >/dev/null 2>&1
    sleep 0.15
  done
fi
post /v1/steps "{\"steps\":[{\"ref\":\"s1\",\"name\":\"Run tests\",\"number\":1,\"status\":\"in_progress\",\"started_at\":$(now_ms)}]}"
i=0
while [ "$i" -lt "$seconds" ]; do
  sleep 1
  i=$((i + 1))
  log "tick $i"
done
[ -n "$fake" ] && log "finished ${job_name:-the job}"
post /v1/steps "{\"steps\":[{\"ref\":\"s1\",\"name\":\"Run tests\",\"number\":1,\"status\":\"completed\",\"conclusion\":\"$([ "$code" = 0 ] && echo success || echo failure)\",\"started_at\":$(now_ms),\"completed_at\":$(now_ms)}]}"

if [ -n "$fake" ]; then
  conclusion=$([ "$code" = 0 ] && echo success || echo failure)
  curl -fsS -m 10 -H 'content-type: application/json' -d "{\"conclusion\":\"$conclusion\"}" "$gh/__fake/runners/$name/done" >/dev/null 2>&1
fi

post /v1/state "{\"state\":\"job_finished\",\"at\":$(now_ms),\"detail\":\"exit_code=$code\"}"
exit 0
