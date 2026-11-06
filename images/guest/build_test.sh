#!/bin/bash
# Tests for build.sh's caching, with a fake docker on PATH: where the
# builder image comes from (CREW_GUEST_REGISTRY, CREW_GUEST_PUSH), and
# kernel-key, which changes with every kernel input and nothing else.
# Needs bash only (macOS or Linux): `images/guest/build_test.sh`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# docker: logs each call; `image inspect` finds nothing; `pull` succeeds
# only if FAKE_PULL=ok.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$FAKE_DOCKER_LOG"
case "$1 $2" in
  "image inspect") exit 1 ;;
  "pull "*) [ "${FAKE_PULL:-}" = ok ] ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/docker"

# builder <log> [env...]: runs `build.sh builder` with the fake docker.
builder() {
  local log=$1
  shift
  : > "$log"
  env -u CREW_GUEST_REGISTRY -u CREW_GUEST_PUSH \
    PATH="$tmp/bin:$PATH" FAKE_DOCKER_LOG="$log" SOURCE_DATE_EPOCH=0 ARCH=x64 \
    "$@" "$here/build.sh" builder 2>/dev/null
}

tag=$(builder "$tmp/none")
case "$tag" in crew-guest-builder:x64-*) ;; *) fail "builder printed '$tag', not its tag" ;; esac
remote="ghcr.example/crew/$tag"

# No registry: built here, nothing pulled or pushed.
grep -q "^docker buildx build" "$tmp/none" || fail "no registry: the builder wasn't built"
grep -qE "^docker (pull|push)" "$tmp/none" && fail "no registry: pulled or pushed"

# In the registry: pulled and tagged, not built.
builder "$tmp/hit" CREW_GUEST_REGISTRY=ghcr.example/crew FAKE_PULL=ok > /dev/null
grep -q "^docker pull .*$remote" "$tmp/hit" || fail "registry hit: $remote wasn't pulled"
grep -q "^docker tag $remote $tag" "$tmp/hit" || fail "registry hit: not tagged $tag"
grep -q "^docker buildx build" "$tmp/hit" && fail "registry hit: built anyway"

# Not in the registry: built, and pushed only with CREW_GUEST_PUSH=1.
builder "$tmp/miss" CREW_GUEST_REGISTRY=ghcr.example/crew > /dev/null
grep -q "^docker buildx build" "$tmp/miss" || fail "registry miss: not built"
grep -q "^docker push" "$tmp/miss" && fail "registry miss: pushed without CREW_GUEST_PUSH"
builder "$tmp/push" CREW_GUEST_REGISTRY=ghcr.example/crew CREW_GUEST_PUSH=1 > /dev/null
grep -q "^docker tag $tag $remote" "$tmp/push" || fail "push: not tagged $remote"
grep -q "^docker push .*$remote" "$tmp/push" || fail "push: $remote wasn't pushed"

# kernel-key, on a copy of the build's inputs.
src="$tmp/guest"
mkdir -p "$src"
cp -R "$here/build.sh" "$here/versions.env" "$here/packages.lock" "$here/packages.txt" \
  "$here/builder" "$here/scripts" "$here/kernel" "$here/rootfs" "$src/"
key() { env -u CREW_GUEST_REGISTRY SOURCE_DATE_EPOCH=0 ARCH="${1:-x64}" "$src/build.sh" kernel-key 2>&1; }

base=$(key)
[[ "$base" =~ ^[0-9a-f]{64}$ ]] || fail "kernel-key printed '$base', not a SHA-256"
[ "$(key)" = "$base" ] || fail "kernel-key isn't stable"
[ "$(key arm64)" != "$base" ] || fail "kernel-key is the same for both arches"

# changes <what> <edit...>: the edit must change the key; then it's undone.
changes() {
  local what=$1 file=$2
  shift 2
  cp "$src/$file" "$tmp/saved"
  "$@" "$src/$file"
  [ "$(key)" != "$base" ] || fail "kernel-key ignores $what"
  cp "$tmp/saved" "$src/$file"
}
same() {
  local what=$1 file=$2
  shift 2
  cp "$src/$file" "$tmp/saved"
  "$@" "$src/$file"
  [ "$(key)" = "$base" ] || fail "kernel-key changes with $what"
  cp "$tmp/saved" "$src/$file"
}
append() { echo "# $RANDOM" >> "$1"; }
bump() { sed -i.bak "s/^\\($1=\\).*/\\1changed/" "$2" && rm -f "$2.bak"; }
kernel_sha() { bump KERNEL_SHA256 "$1"; }
runner_version() { bump RUNNER_VERSION "$1"; }
snapshot() { sed -i.bak 's/^snapshot .*/snapshot 20990101T000000Z/' "$1" && rm -f "$1.bak"; }

changes "the config" kernel/x64.config append
changes "the fragment" kernel/x64.fragment append
changes "the kernel build script" kernel/build-in-container.sh append
changes "the kernel fetch" kernel/fetch.sh append
changes "the kernel's pins" versions.env kernel_sha
changes "the builder" builder/Dockerfile append
changes "the builder's apt sources" scripts/apt-sources.sh append
changes "the snapshot" packages.lock snapshot
same "the other arch's config" kernel/arm64.config append
same "the guest's packages" packages.txt append
same "a non-kernel pin" versions.env runner_version
same "the rootfs scripts" rootfs/install.sh append

[ "$failures" -eq 0 ] || { echo "build_test: $failures failure(s)" >&2; exit 1; }
echo "build_test: ok"
