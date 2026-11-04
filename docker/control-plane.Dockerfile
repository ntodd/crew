# The Crew control plane as a release (spec §5.2, §20.1 item 7), Foreman's
# image for Crew. The release is compiled for one database (CREW_DB):
#
#   docker build -f docker/control-plane.Dockerfile -t crew .
#   docker build -f docker/control-plane.Dockerfile --build-arg CREW_DB=postgres -t crew:pg .
#
# The release workflow also passes the version and the release key's public
# half, and puts the release's signed files in docker/release/ first:
#
#   docker/release/agents/   crew-<agent|cache>-<version>-<target>.tar.gz,
#                            each with its .sha256 and .sig
#   docker/release/images/   crew-guest-<version>-<arch>.manifest.json and
#                            .manifest.sig, without the kernel or rootfs
#
# The control plane registers them at boot (CREW_AGENT_RELEASE_DIR,
# CREW_IMAGE_RELEASE_DIR), and downloads the images' large files from the
# GitHub release, checked against the signed manifests. Whatever is in
# docker/release/ goes into the image, so leave it empty for an image that
# carries no release.
#
# Both base images are pinned by digest; bumping them is a supply-chain
# review (docs/releasing.md).
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim@sha256:3f936c778234d0cce9d91dd61013cd2c830a215334bea598e4f5c666f8bb95bf
ARG RUNTIME_IMAGE=debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

FROM ${ELIXIR_IMAGE} AS build
ARG CREW_DB=sqlite
ENV MIX_ENV=prod CREW_DB=${CREW_DB}
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src
COPY apps/crew_protocol apps/crew_protocol
# The Flatcar pins the Ignition compiles in (Crew.Boxes.Flatcar).
COPY images/flatcar/VERSION images/flatcar/VERSION
COPY apps/crew/mix.exs apps/crew/mix.lock apps/crew/
WORKDIR /src/apps/crew
RUN mix deps.get --only prod --check-locked
COPY apps/crew/config config
RUN mix deps.compile

COPY apps/crew/priv priv
COPY apps/crew/assets assets
COPY apps/crew/lib lib
COPY apps/crew/rel rel
# Set late, so a new version doesn't rebuild the dependencies.
ARG CREW_VERSION=0.1.0
ENV CREW_VERSION=${CREW_VERSION}
RUN mix assets.setup && mix compile && mix assets.deploy && mix release

FROM ${RUNTIME_IMAGE}
# The database the release was built for. The release itself knows; this
# is for whoever inspects the image or runs it, and crew-update reads it.
ARG CREW_DB=sqlite
ENV CREW_DB=${CREW_DB}
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod PHX_SERVER=true

# A fixed id, so the data volume stays the app's whatever a newer base
# image does with its system users. Its home is the data volume's mount
# point, so a new volume starts out the app's.
RUN groupadd --system --gid 9000 crew \
  && useradd --system --uid 9000 --gid crew --create-home --home-dir /var/lib/crew --shell /usr/sbin/nologin crew
WORKDIR /app
# The host's updater (docker/crew-update) installs and refreshes itself
# from here, reading the image, never the running container.
COPY --chmod=0755 docker/crew-update /app/updater/crew-update
# Root's, and read-only to the app: what it runs can't be changed from
# inside. The release's scratch files go to /tmp instead.
COPY --from=build /src/apps/crew/_build/prod/rel/crew ./
ENV RELEASE_TMP=/tmp
COPY docker/release/agents/ /app/release/agents/
COPY docker/release/images/ /app/release/images/
ENV CREW_AGENT_RELEASE_DIR=/app/release/agents CREW_IMAGE_RELEASE_DIR=/app/release/images
# The release key the files above were signed with, as a default for
# CREW_RELEASE_PUBLIC_KEY (base64). The release workflow checks it's the
# key the sign job used; the Deployment page shows its fingerprint.
ARG CREW_RELEASE_PUBLIC_KEY=""
ENV CREW_RELEASE_PUBLIC_KEY=${CREW_RELEASE_PUBLIC_KEY}
ENV DATABASE_PATH=/var/lib/crew/crew.db
USER crew
# 4000: the UI and agents (tailscale serve); 4001: GitHub's webhooks
# (Tailscale Funnel), §6.2. docker/compose.yml publishes both on the
# host's loopback only.
EXPOSE 4000 4001
# 200 once the app is up and its database answers. 127.0.0.1 is exempt
# from the CREW_FORCE_SSL redirect.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT:-4000}/healthz" || exit 1
CMD ["/app/bin/crew", "start"]
# What crew-update compares versions by. Last, so a new version only
# changes this layer.
ARG CREW_VERSION=0.1.0
LABEL org.opencontainers.image.version=${CREW_VERSION}
