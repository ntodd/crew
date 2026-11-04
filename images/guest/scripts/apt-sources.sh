#!/bin/bash
# apt sources for the guest image and its builder (docs/crew_spec.md §13.1).
# Runs as root in an ubuntu:24.04 container.
#
#   apt-sources.sh snapshot <YYYYMMDDTHHMMSSZ>
#       Ubuntu from snapshot.ubuntu.com at that time, then ca-certificates.
#   apt-sources.sh thirdparty
#       Docker's and PGDG's repos, each key checked against its pinned
#       fingerprint (DOCKER_APT_KEY_FPR, PGDG_APT_KEY_FPR).
#   apt-sources.sh live
#       What the finished image keeps: the live Ubuntu archive. The
#       third-party repos stay as they are.
#
# The image has no CA bundle until ca-certificates is installed, so the
# first `apt-get update` doesn't verify the snapshot service's TLS
# certificate. That doesn't weaken the pin: apt checks InRelease against
# ubuntu-archive-keyring and every package against InRelease's hashes,
# whatever the transport.
set -euo pipefail

sources=/etc/apt/sources.list.d/ubuntu.sources
keyrings=/etc/apt/keyrings

apt_conf() {
  cat > /etc/apt/apt.conf.d/80crew-build <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
APT::Get::Assume-Yes "true";
Dpkg::Use-Pty "false";
EOF
}

ubuntu_sources() {
  local uri=$1
  cat > "$sources" <<EOF
Types: deb
URIs: $uri
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  rm -f /etc/apt/sources.list
}

# Downloads an armored key, refuses it unless it holds exactly one primary
# key with the pinned fingerprint, and installs it dearmored.
fetch_key() {
  local name=$1 url=$2 fpr=$3 tmp
  tmp=$(mktemp -d)
  curl -fsSL --retry 5 --retry-all-errors -o "$tmp/key.asc" "$url"
  local primaries
  primaries=$(gpg --show-keys --with-colons "$tmp/key.asc" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
  if [ "$primaries" != "$fpr" ]; then
    echo "apt-sources: $name key at $url has primary key(s) [$primaries], want $fpr" >&2
    exit 1
  fi
  mkdir -p "$keyrings"
  gpg --dearmor < "$tmp/key.asc" > "$keyrings/$name.gpg"
  chmod 0644 "$keyrings/$name.gpg"
  rm -rf "$tmp"
  echo "apt-sources: $name key $fpr"
}

arch=$(dpkg --print-architecture)

case "${1:?snapshot|thirdparty|live}" in
snapshot)
  ts=${2:?snapshot timestamp}
  [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "apt-sources: bad snapshot '$ts'" >&2; exit 1; }
  apt_conf
  ubuntu_sources "https://snapshot.ubuntu.com/ubuntu/$ts/"
  apt-get -o Acquire::https::Verify-Peer=false update -qq
  apt-get -o Acquire::https::Verify-Peer=false install -qq --no-install-recommends ca-certificates >/dev/null
  apt-get update -qq
  ;;
thirdparty)
  : "${DOCKER_APT_KEY_FPR:?}" "${PGDG_APT_KEY_FPR:?}"
  fetch_key docker https://download.docker.com/linux/ubuntu/gpg "$DOCKER_APT_KEY_FPR"
  fetch_key pgdg https://www.postgresql.org/media/keys/ACCC4CF8.asc "$PGDG_APT_KEY_FPR"
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $arch
Signed-By: $keyrings/docker.gpg
EOF
  # apt.postgresql.org keeps only the latest few versions; the archive
  # keeps every one, so a pinned version still installs after PGDG moves
  # on. The archive also carries pre-releases, hence its low priority:
  # `make lock` takes a version from it only if the main repo lacks one.
  cat > /etc/apt/sources.list.d/pgdg.sources <<EOF
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: noble-pgdg
Components: main
Architectures: $arch
Signed-By: $keyrings/pgdg.gpg

Types: deb
URIs: https://apt-archive.postgresql.org/pub/repos/apt
Suites: noble-pgdg-archive
Components: main
Architectures: $arch
Signed-By: $keyrings/pgdg.gpg
EOF
  cat > /etc/apt/preferences.d/50pgdg-archive <<'EOF'
Package: *
Pin: origin apt-archive.postgresql.org
Pin-Priority: 100
EOF
  apt-get update -qq
  ;;
live)
  if [ "$arch" = amd64 ]; then
    ubuntu_sources http://archive.ubuntu.com/ubuntu/
  else
    ubuntu_sources http://ports.ubuntu.com/ubuntu-ports/
  fi
  # The security pocket comes from security.ubuntu.com on amd64.
  if [ "$arch" = amd64 ]; then
    sed -i 's/^Suites: noble noble-updates noble-security$/Suites: noble noble-updates/' "$sources"
    cat >> "$sources" <<'EOF'

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  fi
  rm -f /etc/apt/apt.conf.d/80crew-build
  ;;
*)
  echo "apt-sources: unknown mode $1" >&2
  exit 1
  ;;
esac
