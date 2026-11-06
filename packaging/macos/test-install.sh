#!/bin/sh
# Tests install-macos.sh without root or changing this Mac: a dry run,
# whose LaunchDaemons and agent/env are rendered and checked.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

key=$(grep -v '^#' "$here/../../images/guest/keys/test-signing.pub" | tr -d ' \n')

CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run \
  --url wss://crew.example.ts.net/agent/websocket --token cj_test --name m4-test \
  --release-key "$key" --data-dir "/Library/Application Support/Crew Test" > "$out/log"

fail() { echo "FAIL: $*" >&2; cat "$out/log" >&2; exit 1; }
has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }

for p in com.crew.vzd com.crew.agent; do
  plutil -lint "$out/$p.plist" >/dev/null || fail "$p.plist isn't a valid plist"
done

# Both run from the agent's release, which updates itself (§20.2):
# crew-vzd from agent/current, the agent through crew-launch.
vzd="$out/com.crew.vzd.plist"
[ "$(plutil -extract UserName raw "$vzd")" = _crewvm ] || fail "crew-vzd must run as _crewvm"
[ "$(plutil -extract AbandonProcessGroup raw "$vzd")" = true ] || fail "helpers must outlive crew-vzd"
[ "$(plutil -extract KeepAlive raw "$vzd")" = true ] || fail "crew-vzd must be kept alive"
args=$(plutil -extract ProgramArguments json -o - "$vzd")
echo "$args" | grep -qF '"\/Library\/Application Support\/Crew Test\/agent\/current\/bin\/crew-vz","daemon"' || fail "crew-vzd's binary: $args"
echo "$args" | grep -qF '"--sandbox","\/Library\/Application Support\/Crew Test\/agent\/current\/share\/sandbox.sb"' || fail "helpers must be sandboxed: $args"
echo "$args" | grep -qF 'Crew Test\/run\/vzd.sock' || fail "socket path: $args"

agent="$out/com.crew.agent.plist"
[ "$(plutil -extract UserName raw "$agent")" = _crewagent ] || fail "the agent must run as _crewagent"
[ "$(plutil -extract GroupName raw "$agent")" = crewvm ] || fail "the agent must be in crewvm"
[ "$(plutil -extract KeepAlive raw "$agent")" = true ] || fail "the agent must be kept alive"
plutil -extract ProgramArguments json -o - "$agent" | grep -qF 'Crew Test\/agent\/current\/bin\/crew-launch' ||
  fail "the agent must start through crew-launch"

env="$out/env"
has "$env" "CREW_URL='wss://crew.example.ts.net/agent/websocket'"
has "$env" "CREW_JOIN_TOKEN='cj_test'"
has "$env" "CREW_DATA_DIR='/Library/Application Support/Crew Test'"
has "$env" "CREW_DRIVER=vz"
has "$env" "CREW_VZD_SOCKET='/Library/Application Support/Crew Test/run/vzd.sock'"
has "$env" "CREW_VZ_BIN='/Library/Application Support/Crew Test/agent/current/bin/crew-vz'"
has "$env" "CREW_RELEASE_PUBLIC_KEY='$key'"
# The env file parses as sh, spaces and all.
# shellcheck disable=SC1090
( set -a; . "$env"; [ "$CREW_DATA_DIR" = "/Library/Application Support/Crew Test" ] ) || fail "env doesn't source"

has "$out/log" "+ write /Library/Application Support/Crew Test/agent/env (0600 _crewagent:crewvm)"
# _crewvm runs crew-vz from the agent's release, so it can reach it.
has "$out/log" "'chmod' '0750' '/Library/Application Support/Crew Test/agent'"
# The release goes beside any other, as the agent's own, and current to it.
has "$out/log" "'ditto' '$here' '/Library/Application Support/Crew Test/agent/.install.0.0.0'"
has "$out/log" "'chown' '-R' '_crewagent:crewvm' '/Library/Application Support/Crew Test/agent/.install.0.0.0'"
has "$out/log" "'ln' '-sfn' '0.0.0' '/Library/Application Support/Crew Test/agent/current'"
has "$out/log" "'launchctl' 'bootstrap' 'system' '/Library/LaunchDaemons/com.crew.vzd.plist'"
grep -q "/usr/local/crew" "$out/log" && fail "nothing goes in /usr/local/crew any more"
boot=$(grep -n "bootout' 'system/com.crew.agent'" "$out/log" | cut -d: -f1)
copy=$(grep -n "'ditto'" "$out/log" | cut -d: -f1)
[ "$boot" -lt "$copy" ] || fail "the release was replaced under a running agent"

# A release downloaded in a browser carries com.apple.quarantine, which
# ditto copies, and Gatekeeper then refuses its unnotarized binaries
# (erlexec first) when launchd starts them. The installed copy loses it
# before anything runs from it.
has "$out/log" "'xattr' '-dr' 'com.apple.quarantine' '/Library/Application Support/Crew Test/agent/.install.0.0.0'"
unq=$(grep -n "'xattr' '-dr' 'com.apple.quarantine'" "$out/log" | cut -d: -f1)
start=$(grep -n "'launchctl' 'bootstrap'" "$out/log" | head -n 1 | cut -d: -f1)
[ "$copy" -lt "$unq" ] && [ "$unq" -lt "$start" ] || fail "quarantine must be cleared after the copy, before the services start"

# A key that isn't one is refused.
"$here/install-macos.sh" --dry-run --url wss://x --token cj_t --name m4 --release-key nope > /dev/null 2>&1 &&
  fail "a bad release key was accepted"

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

# --cache-vm (§12.3, §15.6): the mac-vm launcher makes the cache VM with
# the box's join token, then the agent gets its MAC and the cache's
# management token, and root's daemon restarts it when the agent asks.
hostvm="$out/hostvm"
CREW_HOSTVM_DIR="$hostvm" CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run --cache-vm \
  --url wss://crew.example.ts.net/agent/websocket --token cj_test --name m1ultra > "$out/log4"
has "$out/log4" "'curl' '-fsSL' '-o'"
has "$out/log4" "'https://crew.example.ts.net/agent/mac-vm.sh'"
has "$out/log4" "'--role' 'cache' '--token' 'cj_test'"
run_line=$(grep -n "'--role' 'cache'" "$out/log4" | cut -d: -f1)
agent_line=$(grep -n "bootstrap' 'system' '/Library/LaunchDaemons/com.crew.agent.plist'" "$out/log4" | cut -d: -f1)
[ "$run_line" -lt "$agent_line" ] || fail "the cache VM must be up before the agent starts"

# Once it exists, a run picks up its MAC and token instead of making another.
mkdir -p "$hostvm/cachevm"
printf 'name=cachevm\nmac=52:54:00:0a:0b:0c\nrole=cache\n' > "$hostvm/cachevm/box.conf"
echo cm_cache-token-0123456789abcdef0123456789 > "$hostvm/cachevm/mgmt-token"
rm -f "$out/env"
CREW_HOSTVM_DIR="$hostvm" CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run --cache-vm \
  --url wss://crew.example.ts.net/agent/websocket --token cj_test --name m1ultra > "$out/log5"
grep -q "'--role' 'cache'" "$out/log5" && fail "a second cache VM was made"
has "$out/env" "CREW_VZ_CACHE_MAC='52:54:00:0a:0b:0c'"
has "$out/env" "CREW_CACHE_MGMT_TOKEN='cm_cache-token-0123456789abcdef0123456789'"
restart="$out/com.crew.hostvm-restart.plist"
plutil -lint "$restart" >/dev/null || fail "com.crew.hostvm-restart.plist isn't a valid plist"
plutil -extract WatchPaths json -o - "$restart" | grep -qF 'Crew\/run\/restart-cachevm' ||
  fail "the restart daemon must watch run/restart-cachevm"
args=$(plutil -extract ProgramArguments json -o - "$restart")
echo "$args" | grep -qF '"restart","--role","cache","--trigger"' || fail "restart daemon's command: $args"
has "$out/log5" "'launchctl' 'bootstrap' 'system' '/Library/LaunchDaemons/com.crew.hostvm-restart.plist'"

# A reinstall without --cache-vm keeps the cache VM's lines.
rm -f "$out/env"
cat > "$data/agent/env" <<'ENV'
CREW_URL='wss://old.example.ts.net/agent/websocket'
CREW_BOX_NAME='m1ultra'
CREW_VZ_CACHE_MAC='52:54:00:0a:0b:0c'
CREW_CACHE_MGMT_TOKEN='cm_cache-token-0123456789abcdef0123456789'
ENV
CREW_HOSTVM_DIR="$hostvm" CREW_DRY_RUN_OUT="$out" "$here/install-macos.sh" --dry-run --data-dir "$data" > /dev/null
[ "$(grep -c '^CREW_VZ_CACHE_MAC=' "$out/env")" = 1 ] || fail "the cache VM's MAC was lost or doubled"
[ "$(grep -c '^CREW_CACHE_MGMT_TOKEN=' "$out/env")" = 1 ] || fail "the cache's token was lost or doubled"

# Uninstall stops the VMs: helpers outlive crew-vzd by design.
"$here/install-macos.sh" --dry-run --uninstall > "$out/log3"
has "$out/log3" "'launchctl' 'bootout' 'system/com.crew.agent'"
has "$out/log3" "'launchctl' 'bootout' 'system/com.crew.hostvm-restart'"
has "$out/log3" "'pkill' '-KILL' '-U' '_crewvm' '-f' 'crew-vz run'"
agent_line=$(grep -n "bootout' 'system/com.crew.agent'" "$out/log3" | cut -d: -f1)
kill_line=$(grep -n "'pkill'" "$out/log3" | cut -d: -f1)
[ "$agent_line" -lt "$kill_line" ] || fail "VMs were stopped before the agent, which could start more"

echo "install-macos.sh: ok"
