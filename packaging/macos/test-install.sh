#!/bin/sh
# Tests install-macos.sh without root or changing this Mac: a dry run,
# whose LaunchDaemons and agent/env are rendered and checked.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run \
  --url wss://crew.example.ts.net/agent/websocket --token cj_test --name m4-test \
  --data-dir "/Library/Application Support/Crew Test" > "$out/log"

fail() { echo "FAIL: $*" >&2; cat "$out/log" >&2; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }

for p in com.crew.vzd com.crew.agent; do
  plutil -lint "$out/$p.plist" >/dev/null || fail "$p.plist isn't a valid plist"
done

vzd="$out/com.crew.vzd.plist"
[ "$(plutil -extract UserName raw "$vzd")" = _crewvm ] || fail "crew-vzd must run as _crewvm"
[ "$(plutil -extract AbandonProcessGroup raw "$vzd")" = true ] || fail "helpers must outlive crew-vzd"
[ "$(plutil -extract KeepAlive raw "$vzd")" = true ] || fail "crew-vzd must be kept alive"
args=$(plutil -extract ProgramArguments json -o - "$vzd")
echo "$args" | grep -qF '"--sandbox","\/usr\/local\/crew\/share\/sandbox.sb"' || fail "helpers must be sandboxed: $args"
echo "$args" | grep -qF 'Crew Test\/run\/vzd.sock' || fail "socket path: $args"

agent="$out/com.crew.agent.plist"
[ "$(plutil -extract UserName raw "$agent")" = _crewagent ] || fail "the agent must run as _crewagent"
[ "$(plutil -extract GroupName raw "$agent")" = crewvm ] || fail "the agent must be in crewvm"

env="$out/env"
has "$env" "CREW_URL='wss://crew.example.ts.net/agent/websocket'"
has "$env" "CREW_JOIN_TOKEN='cj_test'"
has "$env" "CREW_DATA_DIR='/Library/Application Support/Crew Test'"
has "$env" "CREW_DRIVER=vz"
has "$env" "CREW_VZD_SOCKET='/Library/Application Support/Crew Test/run/vzd.sock'"
# The env file parses as sh, spaces and all.
# shellcheck disable=SC1090
( set -a; . "$env"; [ "$CREW_DATA_DIR" = "/Library/Application Support/Crew Test" ] ) || fail "env doesn't source"

has "$out/log" "+ write /Library/Application Support/Crew Test/agent/env (0600 _crewagent:crewvm)"
has "$out/log" "'chmod' '0700' '/Library/Application Support/Crew Test/agent'"
has "$out/log" "'launchctl' 'bootstrap' 'system' '/Library/LaunchDaemons/com.crew.vzd.plist'"

# --no-sandbox drops it; refusals.
CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run --no-sandbox --url wss://x/agent/websocket --token cj_t --name m4 > /dev/null
plutil -extract ProgramArguments json -o - "$out/com.crew.vzd.plist" | grep -q sandbox && fail "--no-sandbox kept the sandbox"
"$here/install-macos.sh" --dry-run --url ws://x --token cj_t --name m4 > /dev/null 2>&1 && fail "ws:// was accepted"
"$here/install-macos.sh" --dry-run --url wss://x --token cj_t --name "Not A Label" > /dev/null 2>&1 && fail "a bad name was accepted"

echo "install-macos.sh: ok"
