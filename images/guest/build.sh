#!/bin/bash
# Builds the job VM guest image (docs/crew_spec.md §13.1). Every step runs
# in Docker, so the host needs only Docker (and Elixir for the manifest).
# The Makefile is the usual way in; each target is one step here:
#
#   build.sh builder        the build-tools image (builder/Dockerfile)
#   build.sh kernel-config  regenerate kernel/<arch>.config from the fragment
#   build.sh kernel         fetch, verify and build: out/<arch>/kernel/
#   build.sh kernel-check [config]
#                           check kernel/<arch>.config, or another full
#                           config (kernel/check.sh)
#   build.sh kernel-check-test
#                           check.sh's own tests
#
# Env: ARCH (arm64, the default, or x64); OUT (default out/<arch>).
# Caches: the Docker volume crew-guest-kernel (kernel downloads, source
# and object trees).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=versions.env
. "$here/versions.env"

ARCH=${ARCH:-arm64}
case "$ARCH" in
  arm64) platform=linux/arm64 kimage=Image ;;
  x64) platform=linux/amd64 kimage=vmlinux ;;
  *) echo "build: ARCH must be arm64 or x64" >&2; exit 1 ;;
esac
[ -f "$here/kernel/$ARCH.fragment" ] || { echo "build: no kernel/$ARCH.fragment yet" >&2; exit 1; }

out=${OUT:-$here/out/$ARCH}
mkdir -p "$out"
out="$(cd "$out" && pwd)"

lock="$here/packages.lock"
UBUNTU_IMAGE=$(awk '$1 == "base" { print $2 }' "$lock")
UBUNTU_SNAPSHOT=$(awk '$1 == "snapshot" { print $2 }' "$lock")
: "${UBUNTU_IMAGE:?packages.lock has no base}" "${UBUNTU_SNAPSHOT:?packages.lock has no snapshot}"

# Timestamps baked into the build (the kernel's, the tarballs'): the last
# commit's, so they don't change from one build of a commit to the next.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$repo" log -1 --format=%ct)}
export SOURCE_DATE_EPOCH

sha256() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@"; }

builder_tag() {
  local h
  h=$( { cat "$here/builder/Dockerfile" "$here/scripts/apt-sources.sh"; echo "$UBUNTU_IMAGE $UBUNTU_SNAPSHOT"; } |
    sha256 | cut -c1-12)
  echo "crew-guest-builder:$ARCH-$h"
}

builder() {
  local tag
  tag=$(builder_tag)
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    echo "== builder $tag"
    docker buildx build --platform "$platform" --load -t "$tag" \
      --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --build-arg UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" \
      -f "$here/builder/Dockerfile" "$here" >&2
  fi
  echo "$tag"
}

# Runs a command in the builder. Extra docker args come before --.
in_builder() {
  local tag args=()
  tag=$(builder)
  while [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  docker run --rm --platform "$platform" -e CREW_ARCH="$ARCH" \
    -e KBUILD_BUILD_TIMESTAMP="@$SOURCE_DATE_EPOCH" -e SOURCE_DATE_EPOCH \
    "${args[@]}" "$tag" "$@"
}

step=${1:?usage: build.sh builder|kernel-config|kernel|kernel-check|kernel-check-test}
case "$step" in
builder)
  builder
  ;;
kernel-config)
  in_builder -v "$here:/guest" -v crew-guest-kernel:/build -- \
    bash /guest/kernel/build-in-container.sh config
  ;;
kernel)
  mkdir -p "$out/kernel"
  in_builder -v "$here:/guest:ro" -v crew-guest-kernel:/build -v "$out/kernel:/out" -- \
    bash /guest/kernel/build-in-container.sh build
  ;;
kernel-check)
  # check-config.sh needs GNU tools: on Linux it runs here, elsewhere in the
  # builder. A config other than the committed one may be given (the built
  # kernel's, out/<arch>/kernel/config).
  cfg=${2:-$here/kernel/$ARCH.config}
  cfg="$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")"
  if [ "$(uname -s)" = Linux ]; then
    "$here/kernel/check.sh" "$cfg" "$ARCH"
  else
    mkdir -p "$repo/tmp/guest-cache"
    in_builder -v "$here:/guest:ro" -v "$(dirname "$cfg"):/cfg:ro" -v "$repo/tmp/guest-cache:/cache" \
      -e CREW_GUEST_CACHE=/cache -- /guest/kernel/check.sh "/cfg/$(basename "$cfg")" "$ARCH"
  fi
  ;;
kernel-check-test)
  if [ "$(uname -s)" = Linux ]; then
    "$here/kernel/check_test.sh" "$ARCH"
  else
    mkdir -p "$repo/tmp/guest-cache"
    in_builder -v "$here:/guest:ro" -v "$repo/tmp/guest-cache:/cache" -e CREW_GUEST_CACHE=/cache -- \
      /guest/kernel/check_test.sh "$ARCH"
  fi
  ;;
*)
  echo "build: unknown step $step" >&2
  exit 1
  ;;
esac
