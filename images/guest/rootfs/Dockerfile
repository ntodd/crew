# The guest image's root filesystem (docs/crew_spec.md §13.1). build.sh
# builds the `rootfs` target as a tar and rootfs/assemble.sh makes it an
# ext4 image; `make lock` builds the `lock` target instead.
#
# Build contexts: the default one is images/guest; crew_guest and
# crew_protocol are apps/crew_guest and apps/crew_protocol; kernel is the
# kernel build's output (modules.tar, release). Every ARG comes from
# versions.env or packages.lock, through build.sh.
ARG UBUNTU_IMAGE
ARG ELIXIR_IMAGE

# Downloads, each checked against its pinned SHA-256 by BuildKit. Later
# stages mount this one, so none of it lands in the image.
FROM scratch AS downloads
ARG RUNNER_VERSION RUNNER_ARCH RUNNER_SHA256
ARG PLAYWRIGHT_CHROMIUM_VERSION PLAYWRIGHT_CFT_PLATFORM
ARG PLAYWRIGHT_CHROMIUM_SHA256 PLAYWRIGHT_HEADLESS_SHELL_SHA256
ARG PLAYWRIGHT_FFMPEG_REVISION PLAYWRIGHT_FFMPEG_ZIP PLAYWRIGHT_FFMPEG_SHA256
ARG REBAR3_VERSION REBAR3_SHA256
ADD --checksum=sha256:${RUNNER_SHA256} \
    https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
    /runner.tar.gz
ADD --checksum=sha256:${PLAYWRIGHT_CHROMIUM_SHA256} \
    https://cdn.playwright.dev/builds/cft/${PLAYWRIGHT_CHROMIUM_VERSION}/${PLAYWRIGHT_CFT_PLATFORM}/chrome-${PLAYWRIGHT_CFT_PLATFORM}.zip \
    /chromium.zip
ADD --checksum=sha256:${PLAYWRIGHT_HEADLESS_SHELL_SHA256} \
    https://cdn.playwright.dev/builds/cft/${PLAYWRIGHT_CHROMIUM_VERSION}/${PLAYWRIGHT_CFT_PLATFORM}/chrome-headless-shell-${PLAYWRIGHT_CFT_PLATFORM}.zip \
    /headless-shell.zip
ADD --checksum=sha256:${PLAYWRIGHT_FFMPEG_SHA256} \
    https://cdn.playwright.dev/dbazure/download/playwright/builds/ffmpeg/${PLAYWRIGHT_FFMPEG_REVISION}/${PLAYWRIGHT_FFMPEG_ZIP} \
    /ffmpeg.zip
ADD --checksum=sha256:${REBAR3_SHA256} \
    https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3 \
    /rebar3

# crew-guest's release (§13.5), with ERTS, built on Ubuntu noble like the
# guest. Its Hex deps are fetched as mix.lock pins them.
FROM ${ELIXIR_IMAGE} AS crew-guest
ARG HEX_VERSION CREW_VERSION
ENV MIX_ENV=prod LANG=C.UTF-8 MIX_HOME=/mix HEX_HOME=/hex
RUN --mount=type=bind,from=downloads,source=/rebar3,target=/tmp/rebar3 \
    mix local.hex "${HEX_VERSION}" --force \
 && install -m 0755 /tmp/rebar3 /usr/local/bin/rebar3 \
 && mix local.rebar rebar3 /usr/local/bin/rebar3 --force
WORKDIR /src/apps/crew_guest
COPY --from=crew_protocol mix.exs mix.lock /src/apps/crew_protocol/
COPY --from=crew_protocol lib /src/apps/crew_protocol/lib
COPY --from=crew_guest mix.exs mix.lock ./
COPY --from=crew_guest config config
RUN mix deps.get --only prod --check-locked && mix deps.compile
COPY --from=crew_guest lib lib
COPY --from=crew_guest priv priv
COPY --from=crew_guest rel rel
RUN CREW_VERSION="${CREW_VERSION}" mix release --path /opt/crew-guest

# Ubuntu, and every package at its locked version. Only the files this
# step reads are mounted, so editing anything else keeps its cache.
FROM ${UBUNTU_IMAGE} AS packages
ARG CREW_ARCH LOCK_MODE=check DOCKER_APT_KEY_FPR PGDG_APT_KEY_FPR
RUN --mount=type=bind,source=packages.txt,target=/crew/packages.txt \
    --mount=type=bind,source=packages.lock,target=/crew/packages.lock \
    --mount=type=bind,source=scripts/apt-sources.sh,target=/crew/scripts/apt-sources.sh \
    --mount=type=bind,source=rootfs/packages.sh,target=/crew/rootfs/packages.sh \
    --mount=type=cache,target=/var/cache/apt,id=crew-guest-apt-${CREW_ARCH},sharing=locked \
    CREW_ARCH="${CREW_ARCH}" LOCK_MODE="${LOCK_MODE}" \
    DOCKER_APT_KEY_FPR="${DOCKER_APT_KEY_FPR}" PGDG_APT_KEY_FPR="${PGDG_APT_KEY_FPR}" \
    bash /crew/rootfs/packages.sh

# What `make lock` reads.
FROM scratch AS lock
COPY --from=packages /var/lib/crew-image/packages.resolved /

FROM packages AS rootfs
RUN --mount=type=bind,source=versions.env,target=/crew/versions.env \
    --mount=type=bind,source=rootfs/install.sh,target=/crew/rootfs/install.sh \
    --mount=type=bind,from=kernel,target=/kernel \
    --mount=type=bind,from=downloads,target=/dl \
    bash /crew/rootfs/install.sh
COPY --from=crew-guest /opt/crew-guest /opt/crew-guest
RUN --mount=type=bind,source=rootfs,target=/crew/rootfs \
    --mount=type=bind,source=hooks,target=/crew/hooks \
    --mount=type=bind,source=conformance,target=/crew/conformance \
    --mount=type=bind,source=scripts,target=/crew/scripts \
    --mount=type=bind,from=crew_guest,source=rel/crew-guest.service,target=/crew-guest-unit \
    bash /crew/rootfs/configure.sh
