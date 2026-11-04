#!/bin/sh
# Boots a fresh dev control plane for the browser tests, pointed at the
# fake GitHub. Playwright starts it (playwright.config.js).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/apps/crew"

db="${E2E_DB:-$root/tmp/e2e/crew.db}"
mkdir -p "$(dirname "$db")"
rm -f "$db" "$db"-*

export CREW_DEV_DATABASE="$db"
export CREW_LOG_DIR="${CREW_LOG_DIR:-$root/tmp/e2e/logs}"
rm -rf "$CREW_LOG_DIR"
export CREW_SETUP_TOKEN="${CREW_SETUP_TOKEN:-e2e-setup-token-0123456789}"
export CREW_GITHUB_API_URL="${CREW_GITHUB_API_URL:-http://localhost:4199}"
export CREW_GITHUB_WEB_URL="${CREW_GITHUB_WEB_URL:-http://localhost:4199}"
export CREW_BASE_URL="${CREW_BASE_URL:-http://localhost:4100}"
export PORT="${PORT:-4100}"
export CREW_HOOK_PORT="${CREW_HOOK_PORT:-4101}"
# The null driver and ws:// agents are allowed (§11.5, §5.3).
export CREW_DEV="${CREW_DEV:-1}"
# Production's style policy: the browser blocks any inline style.
export CREW_STRICT_CSP="${CREW_STRICT_CSP:-1}"

# mise pins the toolchain locally; CI sets it up directly.
run() { if command -v mise >/dev/null 2>&1; then mise exec -- "$@"; else "$@"; fi; }

# The guest image release the control plane's image would carry (§20.1),
# signed with the development test key: a small made-up one, or a real
# build (E2E_IMAGE_RELEASE_DIR=images/guest/out/arm64/release).
export CREW_RELEASE_PUBLIC_KEY="$(grep -v '^#' "$root/images/guest/keys/test-signing.pub" | tr -d ' \n')"
export CREW_IMAGE_DIR="$root/tmp/e2e/images"
rm -rf "$CREW_IMAGE_DIR"
if [ -n "$E2E_IMAGE_RELEASE_DIR" ]; then
  export CREW_IMAGE_RELEASE_DIR="$E2E_IMAGE_RELEASE_DIR"
else
  export CREW_IMAGE_RELEASE_DIR="$root/tmp/e2e/release"
  rm -rf "$CREW_IMAGE_RELEASE_DIR"
  run mix run --no-start "$root/e2e/make_release.exs" "$CREW_IMAGE_RELEASE_DIR"
fi

# The agent and cache tarballs a Flatcar box's Ignition names (§12.2),
# signed with the same key: placeholders, or a real build
# (E2E_AGENT_RELEASE_DIR).
if [ -n "$E2E_AGENT_RELEASE_DIR" ]; then
  export CREW_AGENT_RELEASE_DIR="$E2E_AGENT_RELEASE_DIR"
else
  export CREW_AGENT_RELEASE_DIR="$root/tmp/e2e/agent-release"
  rm -rf "$CREW_AGENT_RELEASE_DIR"
  run mix run --no-start "$root/e2e/make_agent_release.exs" "$CREW_AGENT_RELEASE_DIR"
fi

# Updating the control plane from the Deployment page (§20.3): the
# directory crew-update shares with it, which the browser test writes
# status/ in as the host's updater would.
export CREW_UPDATE_DIR="$root/tmp/e2e/update"
rm -rf "$CREW_UPDATE_DIR"
mkdir -p "$CREW_UPDATE_DIR/request" "$CREW_UPDATE_DIR/status"

run mix ecto.create --quiet
run mix ecto.migrate --quiet
if [ -n "$E2E_SEED" ]; then run mix run "$root/e2e/$E2E_SEED"; fi
if command -v mise >/dev/null 2>&1; then exec mise exec -- mix phx.server; else exec mix phx.server; fi
