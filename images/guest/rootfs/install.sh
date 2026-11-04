#!/bin/bash
# Unpacks what isn't a package (docs/crew_spec.md §13.1), in the rootfs
# Dockerfile's `rootfs` stage:
#   /crew     images/guest
#   /kernel   the kernel build (modules.tar, release)
#   /dl       the downloads stage, every file already checked by SHA-256
set -euo pipefail

# shellcheck source=../versions.env
. /crew/versions.env

# The kernel's modules: defconfig's drivers that aren't built in.
release=$(cat /kernel/release)
rm -rf "/usr/lib/modules/$release"
tar -C /usr/lib -xf /kernel/modules.tar
depmod -a "$release"
echo "install: modules for $release"

# actions/runner, in the runner's home (configure.sh makes it theirs).
runner=/home/runner/actions-runner
rm -rf "$runner"
mkdir -p "$runner"
tar -C "$runner" -xzf /dl/runner.tar.gz
# Running it also proves its .NET dependencies are all in the image.
got=$("$runner/bin/Runner.Listener" --version 2>&1 | tail -1)
if [ "$got" != "$RUNNER_VERSION" ]; then
  echo "install: Runner.Listener --version says '$got', want $RUNNER_VERSION" >&2
  exit 1
fi
echo "install: actions/runner $RUNNER_VERSION"

# Playwright's browsers, laid out as `playwright install` would for
# playwright $PLAYWRIGHT_VERSION: <name>-<revision>/ with its marker. The
# runner owns the directory, so a project on another Playwright version
# can install its own browsers alongside.
pw=/ms-playwright
rm -rf "$pw"
mkdir -p "$pw/.links" "$pw/.crew"
unpack() {
  local zip=$1 dir=$pw/$2
  mkdir -p "$dir"
  unzip -q "$zip" -d "$dir"
  touch "$dir/INSTALLATION_COMPLETE"
}
unpack /dl/chromium.zip "chromium-$PLAYWRIGHT_CHROMIUM_REVISION"
unpack /dl/headless-shell.zip "chromium_headless_shell-$PLAYWRIGHT_CHROMIUM_REVISION"
unpack /dl/ffmpeg.zip "ffmpeg-$PLAYWRIGHT_FFMPEG_REVISION"
# Playwright deletes browsers no installation links to; this one keeps
# ours while a project on another version installs its own.
cat > "$pw/.crew/browsers.json" <<EOF
{
  "comment": "The browsers baked into the Crew guest image (playwright $PLAYWRIGHT_VERSION).",
  "browsers": [
    {"name": "chromium", "revision": "$PLAYWRIGHT_CHROMIUM_REVISION", "installByDefault": true, "browserVersion": "$PLAYWRIGHT_CHROMIUM_VERSION"},
    {"name": "chromium-headless-shell", "revision": "$PLAYWRIGHT_CHROMIUM_REVISION", "installByDefault": true, "browserVersion": "$PLAYWRIGHT_CHROMIUM_VERSION"},
    {"name": "ffmpeg", "revision": "$PLAYWRIGHT_FFMPEG_REVISION", "installByDefault": true}
  ]
}
EOF
printf '%s' "$pw/.crew" > "$pw/.links/crew-guest-image"

# Every library the browsers need must be in the image: Playwright skips
# its own check where DEPENDENCIES_VALIDATED is.
for dir in "$pw"/chromium-* "$pw"/chromium_headless_shell-*; do
  missing=$(find "$dir" -maxdepth 2 -type f \( -name chrome -o -name chrome-headless-shell -o -name '*.so' \) \
    -exec ldd {} \; 2>/dev/null | grep 'not found' | sort -u || true)
  if [ -n "$missing" ]; then
    echo "install: $(basename "$dir") is missing libraries:" >&2
    echo "$missing" >&2
    exit 1
  fi
  touch "$dir/DEPENDENCIES_VALIDATED"
done
ls "$pw"/chromium-*/chrome-*/chrome "$pw"/chromium_headless_shell-*/chrome-*/chrome-headless-shell \
  "$pw"/ffmpeg-*/ffmpeg-linux >/dev/null
echo "install: Playwright $PLAYWRIGHT_VERSION's chromium $PLAYWRIGHT_CHROMIUM_VERSION, headless shell and ffmpeg"
