#!/bin/sh
# Updates the Tailscale system extension from Flatcar's sysext bakery
# (Foreman's update-sysexts, Tailscale only; docs/crew_spec.md §12.1),
# from crew-sysext-update.timer, daily: systemd-sysupdate with the config
# in /etc/sysupdate.tailscale.d. A new one takes effect on the next boot,
# so it's flagged like an OS update, as tailscale-<version>.
set -u

ext=tailscale
before=$(readlink -f "/etc/extensions/$ext.raw")
/usr/lib/systemd/systemd-sysupdate -C "$ext" update || exit 0
after=$(readlink -f "/etc/extensions/$ext.raw")
if [ "$before" != "$after" ]; then
  # tailscale-v1.106.0-x86-64.raw: tailscale-1.106.0
  version=$(basename "$after" .raw | sed -e "s/^$ext-v\{0,1\}//" -e 's/-x86-64$//' -e 's/-arm64$//')
  line="$ext-$version"
  grep -qxF "$line" /run/reboot-required.pkgs 2>/dev/null || echo "$line" >> /run/reboot-required.pkgs
  [ -e /run/reboot-required ] || echo "*** System restart required ***" > /run/reboot-required
fi
