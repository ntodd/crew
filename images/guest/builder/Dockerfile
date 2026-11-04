# The guest image's build tools: the kernel build and its checks, and the
# ext4 assembly. Same base digest and Ubuntu snapshot as the guest
# (packages.lock), so the toolchain is pinned along with everything else.
#
# Built by images/guest/build.sh (`make -C images/guest builder`).
ARG UBUNTU_IMAGE
FROM ${UBUNTU_IMAGE}
ARG UBUNTU_SNAPSHOT
ENV DEBIAN_FRONTEND=noninteractive
COPY scripts/apt-sources.sh /usr/local/sbin/apt-sources.sh
RUN apt-sources.sh snapshot "${UBUNTU_SNAPSHOT}" \
 && apt-get install -qq --no-install-recommends \
      bc bison build-essential ca-certificates cpio curl e2fsprogs flex \
      gnupg gpgv jq kmod libelf-dev libssl-dev python3 xz-utils zstd \
      >/dev/null \
 && rm -rf /var/lib/apt/lists/*
