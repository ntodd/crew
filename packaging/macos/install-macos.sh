#!/bin/sh
# Installs a mac-vz box (§10.2, §11.4) and enrolls it with Crew.
#
#   sudo ./install-macos.sh --url wss://crew.example.ts.net/agent/websocket --token cj_... \
#     --release-key <base64>
#
# Run from the unpacked darwin release (packaging/release/build-darwin.sh):
# the agent's release, with bin/crew-vz, bin/crew-launch, share/sandbox.sb,
# launchd/ and VERSION beside it. It:
#   - creates the crewvm group and the _crewagent and _crewvm users;
#   - lays out the data directory (default /Library/Application Support/Crew);
#   - puts the release in agent/<version>, the agent's (it updates itself
#     there, §20.2), with agent/current pointing at it;
#   - writes agent/env (0600, _crewagent) and the two LaunchDaemons,
#     com.crew.vzd (_crewvm, agent/current/bin/crew-vz) and com.crew.agent
#     (_crewagent, through agent/current/bin/crew-launch), and starts them;
#   - waits for the agent to enroll, then drops the spent join token.
#
# --release-key is the release key (base64, as Add box shows it) the agent
# checks its updates against; without one it refuses updates.
#
# Re-running it installs the release it's run from and keeps the box's
# identity and settings. Other options:
#   --name NAME        the box's name (default: this Mac's short host name)
#   --data-dir DIR     where VMs, images and the agent's state live
#   --no-sandbox       run crew-vz's helpers without the sandbox-exec profile
#   --disable-sleep    pmset -a sleep 0 (a sleeping Mac pauses its jobs)
#   --cache-vm         the box's cache VM (§12.3, §15.6): crew_cache in a
#                      Flatcar VM on this Mac, made first with the join token
#                      by the control plane's mac-vm launcher (--role cache),
#                      and restarted by root's com.crew.hostvm-restart when the
#                      agent asks. Its job VMs then pull through it.
#   --reenroll         enroll again with a new --token (after a revoke)
#   --uninstall        stop and remove the services (keeps the data)
#   --dry-run          print what would be done, change nothing
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
URL=""
TOKEN=""
NAME=""
KEY=""
DATA="/Library/Application Support/Crew"
DAEMONS="/Library/LaunchDaemons"
SANDBOX=1
DISABLE_SLEEP=""
REENROLL=""
UNINSTALL=""
DRY=""
CACHE_VM=""
# The launchers' VMs (the cache VM among them), as mac-vm.sh keeps them.
HOSTVM="${CREW_HOSTVM_DIR:-/Library/Application Support/Crew/hostvm}"

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --release-key) KEY="$2"; shift 2 ;;
    --data-dir) DATA="$2"; shift 2 ;;
    --no-sandbox) SANDBOX=""; shift ;;
    --disable-sleep) DISABLE_SLEEP=1; shift ;;
    --reenroll) REENROLL=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --cache-vm) CACHE_VM=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

fail() { echo "crew: $*" >&2; exit 1; }
say() { echo "crew: $*"; }

# Every change goes through run, so --dry-run shows it instead.
run() {
  if [ -n "$DRY" ]; then
    printf '+'; for a in "$@"; do printf " '%s'" "$a"; done; printf '\n'
  else
    "$@"
  fi
}

# Writes stdin to a file (mode, owner), or shows it under --dry-run.
put() {
  path="$1"; mode="$2"; owner="$3"
  if [ -n "$DRY" ]; then
    # CREW_DRY_RUN_OUT keeps what would be written, for the installer's test.
    if [ -n "${CREW_DRY_RUN_OUT:-}" ]; then
      tee "$CREW_DRY_RUN_OUT/$(basename "$path")" | sed "s|^|    |; 1i\\
+ write $path ($mode $owner):"
    else
      echo "+ write $path ($mode $owner):"; sed 's/^/    /'
    fi
  else
    tmp="$path.tmp.$$"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$path"
  fi
}

[ "$(uname -s)" = Darwin ] || fail "this is the macOS installer; Linux boxes use Flatcar (Add box shows how)"
[ "$(uname -m)" = arm64 ] || fail "mac-vz boxes need Apple silicon"
if [ -z "$DRY" ]; then [ "$(id -u)" -eq 0 ] || fail "run this as root (sudo)"; fi

# -- uninstall ------------------------------------------------------------------

if [ -n "$UNINSTALL" ]; then
  # The agent first, so nothing starts another VM; then crew-vzd, whose
  # helpers outlive it by design (§10.7), so they're stopped by hand.
  for label in com.crew.agent com.crew.hostvm-restart com.crew.vzd; do
    run launchctl bootout "system/$label" 2>/dev/null || true
    run rm -f "$DAEMONS/$label.plist"
  done
  run pkill -KILL -U _crewvm -f 'crew-vz run' || true
  if [ -z "$DRY" ] && pgrep -U _crewvm -f 'crew-vz run' >/dev/null 2>&1; then
    fail "job VMs are still running (pgrep -U _crewvm -f 'crew-vz run')"
  fi
  say "removed the services and stopped every job VM; $DATA (with the agent's releases) is kept"
  if [ -f "$HOSTVM/cachevm/box.conf" ]; then
    say "the cache VM is still there: sudo crew-box uninstall --yes cachevm removes it"
  fi
  exit 0
fi

# -- checks ---------------------------------------------------------------------------

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "macOS 14 or later is needed (this is $(sw_vers -productVersion))"
for f in bin/crew_agent bin/crew-vz bin/crew-launch; do
  [ -x "$here/$f" ] || [ -n "$DRY" ] || fail "$f is missing: run this from the unpacked release"
done
version=$(cat "$here/VERSION" 2>/dev/null || true)
if [ -z "$version" ] && [ -n "$DRY" ]; then version=0.0.0; fi
echo "$version" | grep -Eqx '[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}(-[0-9A-Za-z.]{1,32})?' ||
  fail "VERSION is missing or isn't a release version: run this from the unpacked release"
if [ -n "$KEY" ]; then
  [ "$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] ||
    fail "--release-key must be the release key in base64 (32 bytes), as Add box shows it"
fi

identity="$DATA/agent/identity.json"
enroll=1
if [ -s "$identity" ] && [ -z "$REENROLL" ]; then enroll=""; fi
if [ -n "$enroll" ]; then
  [ -n "$TOKEN" ] || fail "--token is required (Add box on Crew's Boxes page makes one)"
  [ -n "$URL" ] || fail "--url is required"
  case "$URL" in wss://*) ;; *) fail "--url must be wss:// (the agent only talks TLS)" ;; esac
fi
# A reinstall keeps the box's name and URL unless they're given again.
env_value() { [ -f "$DATA/agent/env" ] && sed -n "s/^$1=//p" "$DATA/agent/env" | tail -n 1 | sed "s/^'//; s/'\$//"; }
[ -n "$NAME" ] || NAME=$(env_value CREW_BOX_NAME || true)
[ -n "$NAME" ] || NAME=$(scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]' || hostname -s)
echo "$NAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' || fail "box name '$NAME' isn't a DNS label of 1 to 40 characters (use --name)"

# -- users and group -----------------------------------------------------------------

# A free id below 500, where macOS keeps hidden service accounts.
free_id() {
  kind="$1"; key="$2"
  used=$(dscl . -list "/$kind" "$key" 2>/dev/null | awk '{print $2}')
  id=400
  while echo "$used" | grep -qx "$id"; do id=$((id + 1)); done
  [ "$id" -lt 500 ] || fail "no free $key below 500"
  echo "$id"
}

if dscl . -read /Groups/crewvm >/dev/null 2>&1; then
  gid=$(dscl . -read /Groups/crewvm PrimaryGroupID | awk '{print $2}')
else
  gid=$(free_id Groups PrimaryGroupID)
  run dscl . -create /Groups/crewvm
  run dscl . -create /Groups/crewvm PrimaryGroupID "$gid"
  run dscl . -create /Groups/crewvm RealName "Crew job VMs"
fi

for user in _crewagent _crewvm; do
  if ! dscl . -read "/Users/$user" >/dev/null 2>&1; then
    uid=$(free_id Users UniqueID)
    run dscl . -create "/Users/$user"
    run dscl . -create "/Users/$user" UniqueID "$uid"
    run dscl . -create "/Users/$user" PrimaryGroupID "$gid"
    run dscl . -create "/Users/$user" UserShell /usr/bin/false
    run dscl . -create "/Users/$user" NFSHomeDirectory /var/empty
    run dscl . -create "/Users/$user" IsHidden 1
    run dscl . -create "/Users/$user" RealName "Crew ($user)"
  fi
  run dseditgroup -o edit -a "$user" -t user crewvm
done

# The services stop before their release is replaced; job VMs keep
# running (their helpers outlive crew-vzd, §10.7).
for label in com.crew.agent com.crew.vzd; do
  run launchctl bootout "system/$label" 2>/dev/null || true
done

# -- the data directory (§10.1, §11.2) ------------------------------------------
#
#   agent/   _crewagent:crewvm 0750: identity.json and env (0600), and the
#            releases: <version>/, current (§20.2). _crewvm runs crew-vz
#            from agent/current/bin.
#   vms/     _crewagent:crewvm 0770: each VM's directory, which the helper writes in
#   images/  _crewagent:crewvm 0750: kernels and root filesystems the helper reads
#   run/     _crewvm:crewvm 0770: vzd.sock
#   logs/    _crewagent:crewvm 0770

run mkdir -p "$DATA/agent" "$DATA/vms" "$DATA/images" "$DATA/run" "$DATA/logs"
run chown root:wheel "$DATA"
run chmod 0755 "$DATA"
run chown _crewagent:crewvm "$DATA/agent" "$DATA/vms" "$DATA/images" "$DATA/logs"
run chown _crewvm:crewvm "$DATA/run"
run chmod 0750 "$DATA/agent"
run chmod 0770 "$DATA/vms" "$DATA/run" "$DATA/logs"
run chmod 0750 "$DATA/images"

# -- the release (§20.2) ----------------------------------------------------------
#
# The agent's own, as an update leaves it: agent/<version>, current
# pointing at it, nothing pending.

staged="$DATA/agent/.install.$version"
run rm -rf "$staged"
run ditto "$here" "$staged"
run chown -R _crewagent:crewvm "$staged"
run chmod -R go-w "$staged"
run rm -rf "${DATA:?}/agent/$version"
run mv "$staged" "$DATA/agent/$version"
run ln -sfn "$version" "$DATA/agent/current"
run chown -h _crewagent:crewvm "$DATA/agent/current"
run rm -f "$DATA/agent/previous" "$DATA/agent/update-pending" "$DATA/agent/rolled-back" "$DATA/agent/crashes"

# -- the cache VM (§12.3, §15.6) -------------------------------------------------------
#
# Made once, with the join token, by the control plane's own mac-vm
# launcher; after that its MAC and management token are read back for
# the agent's settings. It needs no agent to come up.

cache_conf="$HOSTVM/cachevm/box.conf"
if [ -n "$CACHE_VM" ] && [ ! -f "$cache_conf" ]; then
  [ -n "$enroll" ] || fail "--cache-vm needs --token (and --reenroll on an enrolled box): the control plane hands out the cache VM's config for a join token"
  base=$(printf '%s' "$URL" | sed 's|^wss://|https://|; s|/agent/websocket$||')
  launcher=$(mktemp)
  say "making the cache VM (mac-vm.sh --role cache from $base)"
  run curl -fsSL -o "$launcher" "$base/agent/mac-vm.sh"
  run sh "$launcher" --role cache --token "$TOKEN"
  run rm -f "$launcher"
fi
cache_mac=""
cache_token=""
if [ -f "$cache_conf" ]; then
  cache_mac=$(sed -n 's/^mac=//p' "$cache_conf" | tail -n 1)
  cache_token=$(cat "$HOSTVM/cachevm/mgmt-token" 2>/dev/null || true)
  echo "$cache_mac" | grep -Eqx '([0-9a-f]{2}:){5}[0-9a-f]{2}' || fail "the cache VM's MAC in $cache_conf isn't one"
  echo "$cache_token" | grep -Eqx '[A-Za-z0-9_-]{32,128}' || fail "the cache VM has no management token in $HOSTVM/cachevm/mgmt-token"
fi

# -- the agent's settings -----------------------------------------------------------

q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

existing_url=$(env_value CREW_URL || true)
existing_key=$(env_value CREW_RELEASE_PUBLIC_KEY || true)
# The admin's own settings (CREW_EXTRA_BLOCKED, reserves...) survive a
# reinstall; only these lines are the installer's.
owned='^(CREW_URL|CREW_JOIN_TOKEN|CREW_BOX_NAME|CREW_DATA_DIR|CREW_DRIVER|CREW_VZD_SOCKET|CREW_VZ_BIN|CREW_RELEASE_PUBLIC_KEY|RELEASE_DISTRIBUTION|HOME)='
# The cache VM's lines are the installer's when it can read them again.
if [ -n "$cache_mac" ]; then owned='^(CREW_URL|CREW_JOIN_TOKEN|CREW_BOX_NAME|CREW_DATA_DIR|CREW_DRIVER|CREW_VZD_SOCKET|CREW_VZ_BIN|CREW_RELEASE_PUBLIC_KEY|RELEASE_DISTRIBUTION|HOME|CREW_VZ_CACHE_MAC|CREW_CACHE_MGMT_TOKEN)='; fi
kept=""
if [ -f "$DATA/agent/env" ]; then kept=$(grep -Ev "$owned" "$DATA/agent/env" || true); fi
KEY=${KEY:-$existing_key}
[ -n "$KEY" ] || say "no --release-key: this box won't take agent updates until it has one"

{
  echo "CREW_URL=$(q "${URL:-$existing_url}")"
  [ -n "$enroll" ] && echo "CREW_JOIN_TOKEN=$(q "$TOKEN")"
  echo "CREW_BOX_NAME=$(q "$NAME")"
  echo "CREW_DATA_DIR=$(q "$DATA")"
  echo "CREW_DRIVER=vz"
  echo "CREW_VZD_SOCKET=$(q "$DATA/run/vzd.sock")"
  echo "CREW_VZ_BIN=$(q "$DATA/agent/current/bin/crew-vz")"
  [ -z "$KEY" ] || echo "CREW_RELEASE_PUBLIC_KEY=$(q "$KEY")"
  if [ -n "$cache_mac" ]; then
    echo "CREW_VZ_CACHE_MAC=$(q "$cache_mac")"
    echo "CREW_CACHE_MGMT_TOKEN=$(q "$cache_token")"
  fi
  echo "RELEASE_DISTRIBUTION=none"
  echo "HOME=/var/empty"
  [ -z "$kept" ] || printf '%s\n' "$kept"
} | put "$DATA/agent/env" 0600 _crewagent:crewvm

if [ -n "$REENROLL" ]; then run rm -f "$identity"; fi

# -- LaunchDaemons ------------------------------------------------------------------

sandbox_args=""
if [ -n "$SANDBOX" ]; then
  sandbox_args="    <string>--sandbox</string>\n    <string>$DATA/agent/current/share/sandbox.sb</string>\n"
fi

render() {
  sed -e "s|__DATA__|$DATA|g" -e "s|__GID__|$gid|g" \
      -e "s|__SANDBOX__|$sandbox_args|" "$here/launchd/$1.plist" | sed 's/\\n/\
/g'
}

for label in com.crew.vzd com.crew.agent; do
  render "$label" | put "$DAEMONS/$label.plist" 0644 root:wheel
  run plutil -lint "$DAEMONS/$label.plist"
done
# The cache VM's restart (§12.1): the agent writes run/restart-cachevm
# (run/ is crewvm's), and root restarts the VM through crew-box.
if [ -n "$cache_mac" ]; then
  run launchctl bootout system/com.crew.hostvm-restart 2>/dev/null || true
  cat <<PLIST | put "$DAEMONS/com.crew.hostvm-restart.plist" 0644 root:wheel
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.crew.hostvm-restart</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOSTVM/bin/crew-box</string>
    <string>restart</string><string>--role</string><string>cache</string>
    <string>--trigger</string><string>$DATA/run/restart-cachevm</string>
  </array>
  <key>WatchPaths</key><array><string>$DATA/run/restart-cachevm</string></array>
  <key>StandardOutPath</key><string>$DATA/logs/hostvm-restart.log</string>
  <key>StandardErrorPath</key><string>$DATA/logs/hostvm-restart.log</string>
</dict>
</plist>
PLIST
  run plutil -lint "$DAEMONS/com.crew.hostvm-restart.plist"
  run launchctl bootstrap system "$DAEMONS/com.crew.hostvm-restart.plist"
fi

# crew-vzd first: the agent's capabilities check it.
run launchctl bootstrap system "$DAEMONS/com.crew.vzd.plist"
run launchctl bootstrap system "$DAEMONS/com.crew.agent.plist"

# -- sleep ----------------------------------------------------------------------------

if [ -n "$DISABLE_SLEEP" ]; then
  run pmset -a sleep 0
elif pmset -g 2>/dev/null | grep -Eq '^[[:space:]]*sleep[[:space:]]+[1-9]'; then
  say "this Mac sleeps when idle, which pauses its jobs: rerun with --disable-sleep, or set it in System Settings"
fi

# -- enrollment -------------------------------------------------------------------

if [ -n "$enroll" ] && [ -z "$DRY" ]; then
  say "waiting for the agent to enroll..."
  i=0
  until [ -s "$identity" ]; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "the agent didn't enroll in 60 s; see $DATA/logs/agent.log"
    sleep 1
  done
  # The join token is single use: once enrolled it's dead weight.
  sed -i '' '/^CREW_JOIN_TOKEN=/d' "$DATA/agent/env"
fi

say "installed. $NAME shows up on Crew's Boxes page once its agent joins."
