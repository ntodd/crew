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
#   build.sh rootfs         the root filesystem: out/<arch>/rootfs.ext4
#   build.sh lock           re-resolve the packages from the snapshot and
#                           rewrite this arch's lines of packages.lock
#
# Env: ARCH (arm64, the default, or x64); OUT (default out/<arch>);
# VERSION (crew-guest's, default 0.1.0-dev).
# Caches: the Docker volumes crew-guest-kernel (kernel downloads, source
# and object trees) and crew-guest-rootfs (the unpacked tree), and
# BuildKit's cache (layers, the apt archive, downloads).
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
    echo "== builder $tag" >&2
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

# The rootfs Dockerfile's inputs: build contexts and pins.
VERSION=${VERSION:-0.1.0-dev}
rootfs_build() {
  local target=$1
  shift
  local sha_runner=RUNNER_SHA256_$ARCH sha_chromium=PLAYWRIGHT_CHROMIUM_SHA256_$ARCH \
    sha_shell=PLAYWRIGHT_HEADLESS_SHELL_SHA256_$ARCH sha_ffmpeg=PLAYWRIGHT_FFMPEG_SHA256_$ARCH
  local cft ffmpeg_zip
  case "$ARCH" in
    arm64) cft=linux-arm64 ffmpeg_zip=ffmpeg-linux-arm64.zip ;;
    x64) cft=linux64 ffmpeg_zip=ffmpeg-linux.zip ;;
  esac
  [ -n "${!sha_runner:-}" ] && [ -n "${!sha_chromium:-}" ] ||
    { echo "build: versions.env has no $ARCH SHA-256s" >&2; exit 1; }
  docker buildx build --platform "$platform" -f "$here/rootfs/Dockerfile" --target "$target" \
    --provenance=false --sbom=false \
    --build-context crew_guest="$repo/apps/crew_guest" \
    --build-context crew_protocol="$repo/apps/crew_protocol" \
    --build-context kernel="$out/kernel" \
    --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --build-arg ELIXIR_IMAGE="$ELIXIR_IMAGE" \
    --build-arg CREW_ARCH="$ARCH" --build-arg CREW_VERSION="$VERSION" \
    --build-arg DOCKER_APT_KEY_FPR="$DOCKER_APT_KEY_FPR" --build-arg PGDG_APT_KEY_FPR="$PGDG_APT_KEY_FPR" \
    --build-arg RUNNER_VERSION="$RUNNER_VERSION" --build-arg RUNNER_ARCH="$ARCH" \
    --build-arg RUNNER_SHA256="${!sha_runner}" \
    --build-arg PLAYWRIGHT_CHROMIUM_VERSION="$PLAYWRIGHT_CHROMIUM_VERSION" \
    --build-arg PLAYWRIGHT_CFT_PLATFORM="$cft" \
    --build-arg PLAYWRIGHT_CHROMIUM_SHA256="${!sha_chromium}" \
    --build-arg PLAYWRIGHT_HEADLESS_SHELL_SHA256="${!sha_shell}" \
    --build-arg PLAYWRIGHT_FFMPEG_REVISION="$PLAYWRIGHT_FFMPEG_REVISION" \
    --build-arg PLAYWRIGHT_FFMPEG_ZIP="$ffmpeg_zip" \
    --build-arg PLAYWRIGHT_FFMPEG_SHA256="${!sha_ffmpeg}" \
    --build-arg HEX_VERSION="$HEX_VERSION" \
    --build-arg REBAR3_VERSION="$REBAR3_VERSION" --build-arg REBAR3_SHA256="$REBAR3_SHA256" \
    "$@" "$here"
}

step=${1:?usage: build.sh builder|kernel-config|kernel|kernel-check|kernel-check-test|rootfs|lock}
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
rootfs)
  [ -f "$out/kernel/modules.tar" ] || { echo "build: no $out/kernel/modules.tar (make kernel)" >&2; exit 1; }
  # The tar streams from BuildKit into the assembly, never touching the
  # Mac's disk; the tree lands in a Docker volume.
  rootfs_build rootfs --output type=tar,dest=- |
    in_builder -i -v crew-guest-rootfs:/work -v "$out:/out" -v "$here:/guest:ro" -- \
      bash /guest/rootfs/assemble.sh
  ;;
lock)
  work="$here/work/lock-$ARCH"
  rm -rf "$work"
  rootfs_build lock --build-arg LOCK_MODE=update --output "type=local,dest=$work"
  resolved="$work/packages.resolved"
  [ -s "$resolved" ] || { echo "build: the lock build wrote nothing" >&2; exit 1; }
  # Keep the header and the other arches' lines; replace this arch's.
  {
    grep -vE '^(arm64|x64) ' "$lock"
    awk -v a="$ARCH" '($1 == "arm64" || $1 == "x64") && $1 != a' "$lock"
    awk -v a="$ARCH" '{ print a, $1, $2 }' "$resolved"
  } > "$lock.new"
  mv "$lock.new" "$lock"
  echo "build: packages.lock: $(wc -l < "$resolved" | tr -d ' ') packages for $ARCH"
  git -C "$repo" --no-pager diff --stat -- "$lock" || true
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
