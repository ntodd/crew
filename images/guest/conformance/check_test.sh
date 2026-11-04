#!/bin/bash
# Tests for the conformance check's input handling (check --validate-only):
# a good object passes, and every kind of bad value refuses the whole run
# before any check, and is never evaluated. Needs bash and jq (macOS or
# Linux): `images/guest/conformance/check_test.sh`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
canary="$tmp/pwned"
failures=0

good='{
  "checks": ["sizing", "isolation", "spoof", "conntrack", "ticks"],
  "targets": [{"label": "host-ssh", "ip": "192.168.64.34", "port": 22}],
  "reach": [{"label": "guest-api", "ip": "10.199.0.1", "port": 7777}],
  "peers": ["10.200.0.6"],
  "foreign_tokens": ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
  "listen_port": 9000,
  "hold_s": 30,
  "ticks": 50,
  "console_mib": 100,
  "conntrack": {"ip": "10.199.0.1", "port": 7777, "count": 2100},
  "size": {"vcpus": 2, "memory_mib": 1024, "disk_gib": 10}
}'

# expect <pass|fail> <name> <jq expression applied to the good object>
expect() {
  local want=$1 name=$2 expr=$3 file="$tmp/c.json" out status
  jq "$expr" <<<"$good" > "$file" || { echo "FAIL $name: bad jq"; failures=$((failures + 1)); return; }
  out=$("$here/check" --validate-only "$file" 2>&1)
  status=$?
  if [ "$want" = pass ] && { [ $status -ne 0 ] || ! grep -qx 'crew-conformance: input ok' <<<"$out"; }; then
    echo "FAIL $name: refused:"; echo "$out"; failures=$((failures + 1)); return
  fi
  if [ "$want" = fail ]; then
    if [ $status -eq 0 ] || ! grep -q '^crew-conformance: input fail ' <<<"$out"; then
      echo "FAIL $name: accepted:"; echo "$out"; failures=$((failures + 1)); return
    fi
    if grep -v '^crew-conformance: input fail ' <<<"$out" | grep -q .; then
      echo "FAIL $name: ran something:"; echo "$out"; failures=$((failures + 1)); return
    fi
  fi
  if [ -e "$canary" ]; then
    echo "FAIL $name: a value was evaluated"; failures=$((failures + 1)); rm -f "$canary"; return
  fi
  echo "ok   $name"
}

expect pass "a good object" '.'
expect pass "only the checks" '{checks: ["sizing"], size: .size}'
expect fail "an unknown check" '.checks += ["sizing;id"]'
expect fail "a check that's a path" '.checks = ["../../bin/sh"]'
expect fail "an unknown field" '.script = "/bin/sh"'
expect fail "an address with a command" ".targets[0].ip = \"1.2.3.4;touch $canary\""
expect fail "an address that's a substitution" ".targets[0].ip = \"\$(touch $canary)\""
expect fail "a label that's a substitution" ".targets[0].label = \"\$(touch $canary)\""
expect fail "a label with a space" '.targets[0].label = "a b"'
expect fail "a port of 0" '.targets[0].port = 0'
expect fail "a port over 65535" '.reach[0].port = 70000'
expect fail "a port as a string" '.reach[0].port = "22"'
expect fail "a peer as a CIDR" '.peers = ["10.200.0.6/30"]'
expect fail "a peer with leading zeros" '.peers = ["010.200.0.6"]'
expect fail "a token with a space" '.foreign_tokens = ["AAAAAAAAAAAAAAAA AAAAAAAAAAAAAAAA"]'
expect fail "a token with a backtick" ".foreign_tokens = [\"AAAAAAAAAAAAAAAA\`touch $canary\`\"]"
expect fail "a hold over an hour" '.hold_s = 3601'
expect fail "ticks as a float" '.ticks = 1.5'
expect fail "a conntrack count over 4096" '.conntrack.count = 5000'
expect fail "a size that isn't a number" '.size.vcpus = "2; reboot"'
expect fail "no checks" 'del(.checks)'
expect fail "not an object" '"sizing"'

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
