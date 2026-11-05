# The mac-vz box's cache VM (docs/crew_spec.md §12.3): says on the
# consoles when crew_cache answers, which the launcher follows for.
set -eu

etc=${CREW_BOX_ETC:-/etc/crew-box}
# shellcheck source=SCRIPTDIR/lib.sh
. "$etc/lib.sh"

i=0
until curl -fsS --max-time 2 http://10.199.0.1/healthz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 120 ] || fail "crew_cache didn't answer within 2 minutes (journalctl -u crew-cache)"
  sleep 1
done
say "cache ready"
