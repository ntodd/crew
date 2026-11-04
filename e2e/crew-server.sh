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

run mix ecto.create --quiet
run mix ecto.migrate --quiet
if [ -n "$E2E_SEED" ]; then run mix run "$root/e2e/$E2E_SEED"; fi
if command -v mise >/dev/null 2>&1; then exec mise exec -- mix phx.server; else exec mix phx.server; fi
