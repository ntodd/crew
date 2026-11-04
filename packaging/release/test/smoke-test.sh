#!/bin/sh
# Tests packaging/release/smoke.sh against made-up Linux tarballs whose
# binaries are scripts that answer as the real ones do.
#
#   packaging/release/test/smoke-test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
smoke=$here/../smoke.sh

pass=0 fail=0
T=""

# fake NAME OUTPUT: a binary that prints OUTPUT for version/--version, and
# "started" for eval.
fake() {
  cat > "$T/root/bin/$1" << EOF
#!/bin/sh
case "\$1" in
  version | --version) echo "$2" ;;
  eval) echo started ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$T/root/bin/$1"
}

# agent VERSION [AGENT_PRINTS]: a linux agent tarball for VERSION.
agent() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/crew-smoke-test.XXXXXX")
  mkdir -p "$T/root/bin" "$T/root/etc/systemd"
  fake crew_agent "crew_agent ${2:-$1}"
  fake crew-vmctl "crew-vmctl $1"
  fake firecracker "Firecracker v1.14.1"
  fake jailer "Jailer v1.14.1"
  echo "table inet crew {}" > "$T/root/etc/nft.conf"
  echo "*filter" > "$T/root/etc/connlimit.rules"
  echo "[Unit]" > "$T/root/etc/systemd/crew-vmctl.service"
}

cache() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/crew-smoke-test.XXXXXX")
  mkdir -p "$T/root/bin"
  fake crew_cache "crew_cache ${2:-$1}"
}

pack() { tar -C "$T/root" -czf "$T/$1" .; }

check() {
  desc=$1 expect=$2 says=$3
  shift 3
  if "$smoke" "$@" > "$T/out" 2>&1; then status=pass; else status=fail; fi
  if [ "$status" = "$expect" ] && grep -qF -- "$says" "$T/out"; then
    pass=$((pass + 1))
    printf 'ok    %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s (%s)\n' "$desc" "$status"
    sed 's/^/      /' "$T/out"
  fi
}

agent 1.2.3
pack crew-agent-1.2.3-linux-amd64.tar.gz
check "a good agent passes" pass "crew-agent-1.2.3-linux-amd64.tar.gz: ok" \
  "$T/crew-agent-1.2.3-linux-amd64.tar.gz" 1.2.3 linux-amd64

agent 1.2.3 0.1.0
pack crew-agent-1.2.3-linux-amd64.tar.gz
check "an agent built without the tag's version fails" fail "crew_agent 0.1.0" \
  "$T/crew-agent-1.2.3-linux-amd64.tar.gz" 1.2.3 linux-amd64

agent 1.2.3
rm "$T/root/bin/jailer"
pack crew-agent-1.2.3-linux-amd64.tar.gz
check "an agent without the jailer fails" fail "bin/jailer" \
  "$T/crew-agent-1.2.3-linux-amd64.tar.gz" 1.2.3 linux-amd64

agent 1.2.3
rm "$T/root/etc/systemd/crew-vmctl.service"
pack crew-agent-1.2.3-linux-amd64.tar.gz
check "an agent without crew-vmctl's units fails" fail "etc/systemd" \
  "$T/crew-agent-1.2.3-linux-amd64.tar.gz" 1.2.3 linux-amd64

agent 1.2.3
fake crew-vmctl "crew-vmctl dev"
pack crew-agent-1.2.3-linux-amd64.tar.gz
check "a crew-vmctl built without the version fails" fail "crew-vmctl dev" \
  "$T/crew-agent-1.2.3-linux-amd64.tar.gz" 1.2.3 linux-amd64

cache 1.2.3
pack crew-cache-1.2.3-linux-arm64.tar.gz
check "a good cache passes" pass "crew-cache-1.2.3-linux-arm64.tar.gz: ok" \
  "$T/crew-cache-1.2.3-linux-arm64.tar.gz" 1.2.3 linux-arm64

cache 1.2.3
pack crew-cache-1.2.4-linux-arm64.tar.gz
check "a tarball named for another version fails" fail "isn't crew-<agent|cache>-1.2.3-linux-arm64.tar.gz" \
  "$T/crew-cache-1.2.4-linux-arm64.tar.gz" 1.2.3 linux-arm64

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
