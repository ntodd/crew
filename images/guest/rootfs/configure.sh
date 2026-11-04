#!/bin/bash
# Configures the guest image (docs/crew_spec.md §13.1), last in the rootfs
# Dockerfile. /crew is images/guest; /crew-guest-unit is crew-guest.service
# from apps/crew_guest/rel. crew-guest's release is already in
# /opt/crew-guest. Ends with checks that what §13.1 asks for is there.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

files=/crew/rootfs/files

# Locales and time: C.UTF-8 by default, as on GitHub's runners, with
# en_US.UTF-8 generated; UTC.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null
echo 'LANG=C.UTF-8' > /etc/default/locale
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
echo Etc/UTC > /etc/timezone

# The runner (§13.1): uid 1001, passwordless sudo, in the docker group. Also
# in adm and systemd-journal, as on GitHub's runners. The base image's
# `ubuntu` user (uid 1000) goes.
if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi
groupadd -g 1001 runner
useradd -u 1001 -g runner -G docker,adm,systemd-journal -m -s /bin/bash runner
install -m 0440 "$files/etc/sudoers.d/runner" /etc/sudoers.d/runner
visudo -cqf /etc/sudoers.d/runner

# The runner's settings: .env (the job-started hook, §19.5) and .path.
# crew-guest adds the cache CA's variables to .env at boot (§13.5).
install -m 0644 "$files/home/runner/actions-runner/.env" /home/runner/actions-runner/.env
install -m 0644 "$files/home/runner/actions-runner/.path" /home/runner/actions-runner/.path
chown -R runner:runner /home/runner /ms-playwright
# Login shells (sudo -i, su -) find the browsers too.
echo 'PLAYWRIGHT_BROWSERS_PATH=/ms-playwright' >> /etc/environment

# The fork-PR hook. actions/runner runs a hook by its extension, so it's
# installed as job-started.sh.
install -D -m 0755 /crew/hooks/job-started /opt/crew/hooks/job-started.sh

# The conformance check (§11.6): crew-guest runs it instead of the runner
# only when the agent's own config has CREW_CONFORMANCE=1. Root's, and
# read-only to everyone else.
install -D -m 0755 /crew/conformance/check /opt/crew/conformance/check
install -m 0644 /crew/conformance/probe.py /crew/conformance/requirements.txt /opt/crew/conformance/

# systemd: crew-guest is the one service that matters; it starts Docker
# itself once Docker's config is written.
install -m 0644 /crew-guest-unit /etc/systemd/system/crew-guest.service
for d in logind.conf.d journald.conf.d system.conf.d; do
  install -D -m 0644 "$files/etc/systemd/$d/crew.conf" "/etc/systemd/$d/crew.conf"
done
install -m 0644 "$files/etc/fstab" /etc/fstab
systemctl set-default multi-user.target >/dev/null
systemctl enable crew-guest.service >/dev/null 2>&1
systemctl disable docker.service docker.socket containerd.service >/dev/null 2>&1
masked=(
  # §13.1
  apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer
  unattended-upgrades.service systemd-networkd-wait-online.service
  motd-news.service motd-news.timer
  # Nothing to ask on a first boot (every boot is one), no logins on the
  # console, and no housekeeping on a disk that lives for one job.
  systemd-firstboot.service getty.target console-getty.service
  e2scrub_all.timer e2scrub_reap.service fstrim.timer dpkg-db-backup.timer
)
systemctl mask "${masked[@]}" >/dev/null 2>&1
# Firecracker x86's graceful stop is ctrl-alt-del (§13.5).
ln -sf /usr/lib/systemd/system/poweroff.target /etc/systemd/system/ctrl-alt-del.target
# The NIC stays eth0, the name in the kernel's ip= argument and the one
# crew-guest disables IPv6 on (§13.2, §13.3). udev's predictable naming
# would rename it (6.18 renames interfaces that are up).
mkdir -p /etc/systemd/network
ln -sf /dev/null /etc/systemd/network/99-default.link

# apt: the finished image points at the live archive, like a hosted
# runner, and keeps no indexes (a job runs apt-get update first).
/crew/scripts/apt-sources.sh live
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin

# Every VM gets its own machine id at boot.
: > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

rm -rf /var/lib/crew-image /tmp/* /var/tmp/* /root/.cache /root/.wget-hsts
find /var/log -type f -exec truncate -s 0 {} +

# What systemd-update-done would write on a first boot, so ldconfig and
# the catalog rebuild (ConditionNeedsUpdate=) don't run on every boot: the
# build already did both. Last, after anything that touches /usr.
usr_ns=$(stat -c %.9Y /usr | tr -d .)
for d in /etc /var; do
  printf '# Written by the Crew guest image build, as systemd-update-done would.\nTIMESTAMP_NSEC=%s\n' \
    "$usr_ns" > "$d/.updated"
  touch -r /usr "$d/.updated"
done

# Checks: what §13.1 asks of the image.
fail() { echo "configure: $*" >&2; exit 1; }
[ "$(id -u runner)" = 1001 ] || fail "runner isn't uid 1001"
id -nG runner | grep -qw docker || fail "runner isn't in the docker group"
sudo -l -U runner | grep -q 'NOPASSWD: ALL' || fail "runner has no passwordless sudo"
[ "$(systemctl is-enabled crew-guest.service)" = enabled ] || fail "crew-guest.service isn't enabled"
for u in docker.service containerd.service docker.socket; do
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = disabled ] || fail "$u isn't disabled"
done
for u in "${masked[@]}"; do
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = masked ] || fail "$u isn't masked"
done
[ -x /opt/crew-guest/bin/crew_guest ] || fail "no crew-guest release"
[ -x /opt/crew/hooks/job-started.sh ] || fail "no job-started hook"
[ -x /opt/crew/conformance/check ] || fail "no conformance check"
[ -f /opt/crew/conformance/probe.py ] || fail "no conformance probe"
echo '{"checks":["sizing"]}' > /tmp/conformance.json
/opt/crew/conformance/check --validate-only /tmp/conformance.json >/dev/null ||
  fail "the conformance check doesn't run here"
rm -f /tmp/conformance.json
grep -qx 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/crew/hooks/job-started.sh' /home/runner/actions-runner/.env ||
  fail "the runner's .env lacks the hook"
for cmd in setpriv resize2fs update-ca-certificates jq curl inotifywait docker; do
  command -v "$cmd" >/dev/null || fail "no $cmd"
done
echo "configure: enabled units:"
systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null | awk "{ print \"  \" \$1 }" || true
