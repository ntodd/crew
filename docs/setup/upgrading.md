# Upgrading the control plane

The control plane runs from [`docker/compose.yml`](../../docker/compose.yml),
with its settings in `/etc/crew/crew.env` and its data (the SQLite
database, logs and mirrored guest images) in the `crew-data` volume. A
release publishes `ghcr.io/<owner>/crew:X.Y.Z` (SQLite) and
`:X.Y.Z-pg` (Postgres), which carry that release's agents, caches and
guest image manifests ([releasing.md](../releasing.md)). Upgrading is a
pull and a restart: migrations run on boot, the image registers what it
carries, and boxes then follow its agent.

Jobs keep running through it. VMs don't depend on the control plane
being up, and boxes reconnect when it's back.

## From the Deployment page

The control plane checks `CREW_UPDATE_REPO`'s releases (default
`ntodd/crew`) daily, and at its first boot; `CREW_UPDATE_CHECK=false`
turns that off. The Deployment page shows the running version and the
newest release, and once the host's updater is installed, an admin's
**Update to X** button.

For SQLite, the page estimates dashboard downtime before you confirm. It
counts the data the updater will archive, including the database, job and
VM logs, and agent releases. Mirrored guest images are excluded. The range
allows for compression, verification and restart. The image download happens
while Crew is still online. Disk speed and migration time vary by host.
For example, 3 GiB gives a rough estimate of 3–10 minutes offline.

The control plane can't replace its own container, so `crew-update`,
a script run as root by a systemd path unit on the host, does it. The
button writes the version to `/var/lib/crew-update/request/`, mounted
into the container, and the updater:

1. takes it only if it's `X.Y.Z` and newer than the running version, and
   pulls that version from the running image's repository (`-pg` for
   Postgres). A version is all the control plane can ask for.
2. stops the control plane and backs up the `crew-data` volume to
   `/var/lib/crew-update/backups/`, keeping the last three. The
   mirrored guest images aren't in the backup: they're large, and the
   control plane downloads them again.
3. pins the version in the `.env` beside `compose.yml` (`CREW_IMAGE`)
   and starts it.
4. waits up to five minutes for `/healthz`. If the new version doesn't
   answer, or keeps restarting, it restores the backup and the previous
   version, so the database is as it was.
5. replaces itself with the copy the new image carries.

Anything else that goes wrong once the control plane is stopped (the
backup fails or fills the disk, systemd's 30-minute timeout stops the
run) also starts the previous version again, with its `.env`, and with
the backup restored if the new version had started. If the host goes
down mid-update, the updater finishes putting the previous version back
when it comes up: it keeps its progress in
`/var/lib/crew-update/run.state`, and the path unit starts it whenever
that file exists.

A backup is read back whole before the update goes on, and again before
a rollback empties the volume to restore it. If it has gone missing or
can't be read by then, the updater restores nothing: it leaves the data
as the new version left it and Crew stopped, and the Deployment page and
`crew-update status` say so. Restore an older backup by hand (below), or
start the new version again, as the release notes suggest.

The page follows along and reconnects once the new version is up. Read
the release notes first all the same: they say whether the protocol
changed and which migrations run.

Install the updater once, as root, from the image the control plane
runs, with the path to its `compose.yml`:

```sh
img=$(sudo docker inspect -f '{{.Config.Image}}' crew)
sudo docker run --rm --entrypoint cat "$img" /app/updater/crew-update |
  sudo sh -s -- install /opt/crew/compose.yml
```

It needs `compose.yml` to mount `/var/lib/crew-update/request` and
`/var/lib/crew-update/status`, as `docker/compose.yml` does; the
installer says so if they're missing. Root's Docker login is what
pulls the image.

On the host:

```sh
sudo crew-update status                 # the last run
sudo journalctl -u crew-update          # what it did, and the new version's logs if it rolled back
ls /var/lib/crew-update/backups/        # the volume backups
```

With Postgres there's no volume backup: take a snapshot at your
provider first. A failed update still goes back to the previous
version, but the database keeps whatever the new version's migrations
did.

To remove it: `sudo systemctl disable --now crew-update.path`, then
delete `/usr/local/sbin/crew-update`, the two
`/etc/systemd/system/crew-update.*` units and `/etc/crew/update.conf`.

What the container can and can't do here: it writes to `request/` and
nowhere else, and reads `status/` read-only. The updater reads at most
a line of at most 32 bytes from `request/version`, after renaming it
out of the container's reach, and acts only on a newer `X.Y.Z` from
the repository already running. So a compromised control plane can ask
for a newer release, or nothing: not another image, not a downgrade,
not a command. Images aren't signed; the updater trusts the registry as
`docker compose pull` does.

## By hand

1. Back up (below).
2. Read the release notes.
3. Point `CREW_IMAGE` at the new version in the `.env` beside
   `compose.yml`, then:

   ```sh
   sudo docker compose pull
   sudo docker compose up -d
   ```

4. `sudo docker compose ps` shows it healthy once `/healthz` answers.
   If the log says a bundled tarball or guest image "wasn't
   registered", the release key the control plane trusts isn't the one
   the release was signed with: compare the Deployment page's
   fingerprint with the release notes'.

## Backing up SQLite

The database runs in WAL mode, so copy the volume with the control
plane stopped:

```sh
cd /opt/crew   # wherever compose.yml is
sudo docker compose stop
sudo docker run --rm -v crew-data:/data:ro -v "$PWD":/backup debian:trixie-slim \
  tar --exclude=./images -czf "/backup/crew-data-$(date +%F).tgz" -C /data .
sudo docker compose start
```

To restore one (an updater backup, or your own):

```sh
sudo docker compose stop
sudo docker run --rm -v crew-data:/data -v /var/lib/crew-update/backups:/backup:ro debian:trixie-slim \
  sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name images -exec rm -rf {} + &&
         tar --numeric-owner -xzf /backup/crew-data-0.2.0-20261104T101500Z.tgz -C /data'
sudo docker compose up -d
```

## Rolling back

Point `CREW_IMAGE` at the previous version and `up -d` again.
Migrations don't run backwards, so check the notes of the release
you're leaving; one that changed the database in a way the older
version can't read means restoring the backup from before the upgrade.

The protocol sets a floor: the control plane accepts agents on its own
protocol and the one before (§10.5), so once boxes run agents on a
newer protocol, a control plane older than that refuses them. The
release notes say when the protocol changes.

## Migrate a mac-vm worker to mac-vz

Apple silicon workers now run the agent on macOS. Each job still gets a fresh
arm64 Linux VM. Virtualization.framework starts those VMs, and Crew's userspace
network stack enforces their network policy. The optional registry and DNS cache
runs in its own Flatcar VM. Size and architecture labels continue to work. Review
repository box restrictions and the new worker's reported capacity before moving
traffic. Account for macOS memory, disk space, other VMs on the Mac, and sleep.

1. After updating the control plane, open the old box in **Boxes**. Crew drains
   it automatically, reaps idle runners and lets busy jobs finish. Wait until the
   VM list is empty. Run `sudo crew-box stop OLD_NAME` on the Mac and keep the
   old VM's disks and installed launcher for recovery. Disable its boot-time
   launch with `sudo launchctl disable system/com.crew.hostvm.OLD_NAME`.
2. For both fresh installs and replacements, choose **Boxes → Add box → mac-vz**.
   Give the replacement a new name. Verify the release key and use the displayed
   Darwin installer command on the Mac. The new join token and key pair identify
   this box. Keep the nested agent's key on its original disk. If the Mac already
   runs a mac-vz worker, use that box and its existing identity.
3. The installer's `--cache-vm` option provisions the cache on a fresh install.
   An existing cache keeps its store, MAC address and management token. If the
   retired worker itself was named `cachevm`, back it up and remove that stopped
   worker with the old launcher before provisioning a cache with the same local name.
4. Check the new box's architecture, firewall and capacity on its box page.
   Run and cancel an arm64 workflow, check DNS and a registry pull, restart the
   agent during another job, and confirm the job finishes and its VM disappears.
   Record the macOS version and hardware with the result. Once satisfied, revoke
   the old box in Crew. Its historical runs remain under its original identity.

If native setup fails, keep the drained box and its disks while repairing the
mac-vz installation. Rerun the installer on an enrolled Mac to preserve its
identity. To repair the cache OS, download the cache reprovision Ignition from
the mac-vz box page and run its reimage command. The cache data disk is retained.
Revocation is permanent. If a control-plane rollback requires the old worker,
restore the previous release before revoking it, enable its original launch job
with `sudo launchctl enable system/com.crew.hostvm.OLD_NAME`, and use the old
launcher to start it.
