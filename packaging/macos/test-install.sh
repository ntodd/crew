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

# A reinstall keeps the box's identity, name, URL and the admin's own
# settings; only the installer's lines are rewritten.
data="$out/data"
mkdir -p "$data/agent"
echo '{"agent_id":"x"}' > "$data/agent/identity.json"
cat > "$data/agent/env" <<'ENV'
CREW_URL='wss://old.example.ts.net/agent/websocket'
CREW_BOX_NAME='m4-old'
CREW_DATA_DIR='/somewhere/else'
CREW_EXTRA_BLOCKED='198.51.100.0/24'
CREW_VZ_HOST_RESERVE_MIB='16384'
ENV
rm -f "$out/env"
CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run --data-dir "$data" > "$out/log2"
has "$out/env" "CREW_URL='wss://old.example.ts.net/agent/websocket'"
has "$out/env" "CREW_BOX_NAME='m4-old'"
has "$out/env" "CREW_DATA_DIR='$data'"
has "$out/env" "CREW_EXTRA_BLOCKED='198.51.100.0/24'"
has "$out/env" "CREW_VZ_HOST_RESERVE_MIB='16384'"
grep -q "CREW_JOIN_TOKEN" "$out/env" && fail "a reinstall wrote a join token"
[ "$(grep -c '^CREW_DATA_DIR=' "$out/env")" = 1 ] || fail "CREW_DATA_DIR twice"

# Uninstall stops the VMs: helpers outlive crew-vzd by design.
"$here/install-macos.sh" --dry-run --uninstall > "$out/log3"
has "$out/log3" "'launchctl' 'bootout' 'system/com.crew.agent'"
has "$out/log3" "'pkill' '-KILL' '-U' '_crewvm' '-f' 'crew-vz run'"
agent_line=$(grep -n "bootout' 'system/com.crew.agent'" "$out/log3" | cut -d: -f1)
kill_line=$(grep -n "'pkill'" "$out/log3" | cut -d: -f1)
[ "$agent_line" -lt "$kill_line" ] || fail "VMs were stopped before the agent, which could start more"

echo "install-macos.sh: ok"
