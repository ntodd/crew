#!/bin/sh
# Build the Debian/Ubuntu enrollment package alongside the signed runtime.
set -eu
version=${1:?version}
out=${2:?output directory}
umask 022
repo=$(cd "$(dirname "$0")/../.." && pwd)
pkg=$(mktemp -d)
chmod 0755 "$pkg"
trap 'rm -rf "$pkg"' EXIT
mkdir -p "$pkg/DEBIAN" "$pkg/usr/sbin" "$pkg/usr/lib/crew-worker" "$pkg/usr/lib/systemd/system" "$out"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: crew-worker
Version: $version
Architecture: amd64
Maintainer: Crew maintainers <noreply@github.com>
Depends: libc6 (>= 2.39), systemd (>= 252), python3, openssl, ca-certificates, curl, iproute2, iptables, nftables, xfsprogs, e2fsprogs, util-linux, passwd, libstdc++6, libssl3 | libssl3t64, libtinfo6
Description: Native Crew job worker enrollment for Debian and Ubuntu
CONTROL
install -m755 "$repo/packaging/debian/enroll.py" "$pkg/usr/sbin/crew-worker-enroll"
install -m644 "$repo/apps/crew/priv/linux/systemd/"* "$pkg/usr/lib/systemd/system/"
for service in crew-agent crew-cache; do
  install -Dm644 "$repo/packaging/debian/$service.conf" "$pkg/usr/lib/systemd/system/$service.service.d/worker.conf"
done
for script in lib quota agent-install root-units root-install agent-rollback; do
  install -m644 "$repo/apps/crew/priv/flatcar/$script.sh" "$pkg/usr/lib/crew-worker/"
done
install -m644 "$repo/packaging/release/release-key.pub" "$pkg/usr/lib/crew-worker/"
echo "$version" > "$pkg/usr/lib/crew-worker/version"
dpkg-deb --root-owner-group --build "$pkg" "$out/crew-worker_${version}_amd64.deb"
