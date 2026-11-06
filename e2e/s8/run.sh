#!/bin/bash
# Spike S8 (docs/crew_spec.md §15.1, Design A): does dockerd 29 with the
# containerd image store pull through crew_cache for registries other
# than Docker Hub, from /etc/docker/certs.d/<registry>/hosts.toml?
#
# crew_cache runs in a container at 10.199.0.1 (as a box's cache does),
# a docker:dind daemon on the same network gets the hosts.toml files
# crew-guest writes, and the cache's stats show the pulls as misses,
# then hits. Needs Docker and the network; leaves nothing behind.
#
#   e2e/s8/run.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/images/guest/versions.env"
dind_image="${S8_DIND_IMAGE:-docker:29.9.2-dind}"
net=crew-s8
token=s8-token
work="$(mktemp -d)"

down() {
  docker rm -f crew-s8-cache crew-s8-dind >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap 'down; rm -rf "$work"' EXIT
down

docker network create --subnet 10.199.0.0/24 --gateway 10.199.0.254 "$net" >/dev/null

echo "s8: starting crew_cache at 10.199.0.1"
docker run -d --name crew-s8-cache --network "$net" --ip 10.199.0.1 -p 127.0.0.1:17780:7780 \
  -v "$root/apps/crew_cache:/src/crew_cache:ro" -v "$root/apps/crew_protocol:/src/crew_protocol:ro" \
  -e MIX_ENV=prod -e CREW_CACHE_DIR=/data -e CREW_CACHE_LISTEN=10.199.0.1 \
  -e CREW_CACHE_DNS_PORT=off -e CREW_CACHE_MGMT_LISTEN=0.0.0.0:7780 -e CREW_CACHE_MGMT_TOKEN="$token" \
  -e CREW_CACHE_MAX_GIB=4 \
  "$ELIXIR_IMAGE" bash -c '
    set -e
    # The amd64 variant of this image has no CA certificates, which Hex needs.
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null; }
    mkdir -p /w && cp -r /src/crew_cache /src/crew_protocol /w/ && rm -rf /w/*/_build /w/*/deps
    cd /w/crew_cache && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
    mix deps.get >/dev/null && mix compile >/dev/null && exec mix run --no-halt' >/dev/null

mgmt() { curl -fsS -H "authorization: Bearer $token" "http://127.0.0.1:17780$1"; }
for _ in $(seq 1 120); do mgmt /stats >/dev/null 2>&1 && break; sleep 2; done
mgmt /stats >/dev/null || { docker logs crew-s8-cache | tail -30; exit 1; }
mgmt /ca.pem > "$work/ca.crt"

# What crew-guest writes (CrewGuest.System.Linux.configure_docker/4).
certs="$work/certs.d"
mkdir -p "$certs/10.199.0.1"
cp "$work/ca.crt" "$certs/10.199.0.1/ca.crt"
for pair in ghcr.io:ghcr.io docker.io:registry-1.docker.io public.ecr.aws:public.ecr.aws; do
  prefix=${pair%%:*} upstream=${pair#*:}
  mkdir -p "$certs/$prefix"
  cat > "$certs/$prefix/hosts.toml" <<TOML
server = "https://$upstream"

[host."https://10.199.0.1/v2/$prefix"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "/etc/docker/certs.d/10.199.0.1/ca.crt"
TOML
done

echo "s8: starting $dind_image"
docker run -d --name crew-s8-dind --privileged --network "$net" --ip 10.199.0.10 \
  -v "$certs:/etc/docker/certs.d:ro" -e DOCKER_TLS_CERTDIR= "$dind_image" >/dev/null
dk() { docker exec crew-s8-dind docker "$@"; }
for _ in $(seq 1 60); do dk info >/dev/null 2>&1 && break; sleep 1; done
echo "s8: $(dk version --format 'docker {{.Server.Version}}'), $(dk info --format '{{range .DriverStatus}}{{index . 0}}={{index . 1}} {{end}}')"

hits() { mgmt /stats | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(f\"{h['host']}:{h['hits']}/{h['misses']}\" for h in d['hosts'] if h['hits'] or h['misses']))"; }

images=(ghcr.io/actions/actions-runner:latest docker.io/library/alpine:3.20 public.ecr.aws/docker/library/busybox:latest)
for i in "${images[@]}"; do dk pull -q "$i" >/dev/null && echo "s8: pulled $i"; done
echo "s8: after the first pulls (hits/misses): $(hits)"
for i in "${images[@]}"; do dk rmi -f "$i" >/dev/null; done
for i in "${images[@]}"; do dk pull -q "$i" >/dev/null; done
echo "s8: after pulling again: $(hits)"

# Not on the allowlist: the cache answers 404 and dockerd goes upstream.
dk pull -q ghcr.io/linuxserver/baseimage-alpine:3.20 >/dev/null && echo "s8: pulled a repo off the allowlist (fallback upstream)"
echo "s8: done"
