# Releasing

A release is one tag, `vX.Y.Z`. Pushing it runs
[`.github/workflows/release.yml`](../.github/workflows/release.yml),
which builds, checks, signs and publishes everything (spec §20.1):

| Job | What it does |
|---|---|
| check | [`packaging/release/check.sh`](../packaging/release/check.sh): the tag is `vX.Y.Z`; every `mix.exs`, read with `CREW_VERSION` set to it, is that version; the release key is committed, isn't the test key, and is the `CREW_RELEASE_PUBLIC_KEY` variable; `docs/releases/vX.Y.Z.md` has a supply-chain review with no suspicious verdict |
| ci | All of [`ci.yml`](../.github/workflows/ci.yml), on the tagged commit |
| native | `crew-vmctl` (Linux) and `crew-vz` (macOS arm64, ad-hoc signed) from `native/vendor` with no network, then `govulncheck` |
| agents | The agent and cache tarballs for linux-amd64 and linux-arm64 (`build-linux.sh`) and the darwin-arm64 agent (`build-darwin.sh`), each built and smoke-tested ([`smoke.sh`](../packaging/release/smoke.sh)) on a runner of its own OS and arch |
| guest | [`guest-image.yml`](../.github/workflows/guest-image.yml): the guest images, built and checked per arch, unsigned |
| sign | The only job in the `release-signing` environment. [`images/guest/sign.sh`](../images/guest/sign.sh) signs every tarball and every guest manifest with openssl, after checking the key's public half is the committed one |
| verify | Checks every signature and file as the control plane and boxes will (`mix crew.verify`, `mix crew_image.verify`) |
| images | The control plane's images, SQLite and Postgres, amd64 and arm64, with the signed tarballs and manifests inside. The SQLite one is started once and must answer `/healthz` and register everything it carries |
| manifest | Joins the arches into `ghcr.io/<owner>/crew:X.Y.Z` and `:X.Y.Z-pg`, and moves `:latest` and `:latest-pg` if this is the highest tag |
| publish | The GitHub release: every tarball, `.sha256`, `.sig`, guest kernel, rootfs, manifest and manifest signature, and `packages.lock.diff`. Its notes are `docs/releases/vX.Y.Z.md`, the release key's fingerprint, the images, the protocol and the migrations since the last release |

Control planes see the release once it's published (they check
`CREW_UPDATE_REPO`'s releases daily), and update from their Deployment
page through `crew-update` ([setup/upgrading.md](setup/upgrading.md)).
Boxes then follow the newest agent their control plane's image carries.

## Setting up, once

### The release key

Make an ed25519 key with openssl, somewhere that isn't synced or backed
up in the clear:

```sh
umask 077
openssl genpkey -algorithm ed25519 -out release.pem
openssl pkey -in release.pem -outform DER | tail -c 32 | openssl base64 -A > release.key
openssl pkey -in release.pem -pubout -outform DER | tail -c 32 | openssl base64 -A; echo
```

`release.key` is the 32-byte seed, base64: the private key. The last
command prints the public key. Then:

1. Put the seed in a password manager, then delete `release.pem` and
   `release.key`. Losing the seed means every box needs its
   `CREW_RELEASE_PUBLIC_KEY` changed by hand; leaking it means anyone
   can sign agents your boxes will run.
2. Commit the public key to `packaging/release/release-key.pub`, with
   its fingerprint as a comment (`mix crew.verify` prints it; it's
   `SHA256:` and the unpadded base64 SHA-256 of the 32 raw bytes):

   ```
   # Crew's release key. Fingerprint SHA256:...
   U7Fx0oC8/8DnSdn/xdqkZoHXDFkJgQa8HCMAbNwk7eU=
   ```

   Put the fingerprint in the README too. The Deployment page tells
   admins to compare their control plane's key with it.
3. Set the repository variable `CREW_RELEASE_PUBLIC_KEY` to the same
   public key. The check job fails unless the two match, and the
   control plane's images are built with it.

`images/guest/keys/test-signing.key` is committed and only for
development; `--release` refuses it everywhere.

### The `release-signing` environment

In the repository's settings, under Environments, create
`release-signing`:

- **Required reviewers:** the maintainers. The sign job waits for one
  of them to approve each release.
- **Deployment branches and tags:** selected only, with a tag rule
  `v*`.
- **Secret** `CREW_RELEASE_SIGNING_KEY`: the seed from `release.key`.

Then protect the tags: a ruleset on `refs/tags/v*` that lets only
maintainers create, update or delete them. Without it, anyone who can
push could make a tag the environment accepts.

### GHCR

The images job pushes with the workflow's own token (`packages:
write`). After the first release, make the `crew` package public, so
hosts pull it without a login, and link it to the repository.

## Cutting a release

1. **Pick the version.** Every `mix.exs` takes `CREW_VERSION`, so there's
   nothing to bump in the code.
2. **Do the bumps that are due** (below), each its own pull request with
   its supply-chain review.
3. **Write `docs/releases/vX.Y.Z.md`:** a `# Crew X.Y.Z` title, what
   changed, anything an operator has to do, and the supply-chain review
   (format below). It becomes the release notes.
4. **Run what needs hardware**, on the tagged commit:
   - the e2e suite against the test App and test repo (spec §23);
   - the aarch64 conformance suite on the M3 (`mac-vm`). Spec §20.1
     names `e2e/release-check.sh` for this, and it isn't written yet:
     run the suite by hand and attach its output to the release once
     it's published.
5. **Tag and push:**

   ```sh
   git tag -s vX.Y.Z -m "Crew X.Y.Z"
   git push origin vX.Y.Z
   ```

6. **Approve the sign job** when it asks.
7. **Check what came out:** the release's assets and notes, the
   fingerprint in them, and `docker buildx imagetools inspect
   ghcr.io/<owner>/crew:X.Y.Z`. Then update a control plane from its
   Deployment page and watch a box follow.

If a job fails before `sign`, nothing is published: fix it on `main`,
delete the tag (`git push --delete origin vX.Y.Z`) and tag again. After
`images` has pushed, the per-arch tags exist but nothing points at them;
re-run the failed jobs. Once the release is published, don't delete or
move it: boxes and control planes may already have it. Release
`X.Y.(Z+1)` instead.

## The cadence and the bumps

Release at least every **21 days**. GitHub stops giving jobs to runners
that fall too far behind, and the guest image's runner only moves with a
release (§13.1). The Images page warns at 14 days behind and alerts at
21.

Each release, bump what's due. Every bump is reviewed (next section).

| Bump | Pinned in | How |
|---|---|---|
| `actions/runner` | `images/guest/versions.env`: `RUNNER_VERSION` and `RUNNER_SHA256_*` | The new release's tarballs' SHA-256s, from GitHub's release |
| Firecracker and its jailer | `native/crew-vmctl/firecracker.env` | Version and SHA-256 per arch; `fetch-firecracker.sh` checks them |
| The kernel's point release | `images/guest/versions.env`: `KERNEL_VERSION`, `KERNEL_SHA256` | Then `make -C images/guest kernel-config` and review the config diff; the tarball's `.sign` must be by a key in `kernel/keys/` |
| The Ubuntu snapshot and base digest | `images/guest/packages.lock` | `make -C images/guest lock ARCH=arm64`, then review the diff, every package that moved |
| Flatcar | `images/flatcar/VERSION`: version, image and kernel SHA-512s, verity hashes | Boxes update themselves; this is the first-boot version |
| The Tailscale sysext | `images/flatcar/VERSION` | Version and SHA-256 per arch |
| vfkit | `images/flatcar/VERSION`: `VFKIT_VERSION`, `VFKIT_SHA256` | The launchers and the darwin tarball download it and check it |
| Go modules, including crew-vz's | `native/go.mod`, `native/go.sum`, `native/vendor/` | `make -C native vendor`; review `vendor/` as code, since it is |
| GitHub Actions | Every `uses:` in `.github/workflows/`, by commit SHA | The new tag's commit, with the tag in the comment |
| Base images | `docker/control-plane.Dockerfile` (`ELIXIR_IMAGE`, `RUNTIME_IMAGE`), `images/guest/versions.env` (`ELIXIR_IMAGE`) | By digest |
| Erlang and Elixir | `mise.toml`, the workflows' `ELIXIR_VERSION` and `OTP_VERSION`, the base images | Together |
| Hex packages | Each app's `mix.lock` | `mix deps.update`; CI runs `mix deps.audit` |
| CI's tools | ShellCheck, actionlint, `govulncheck`, `ignition-validate`, in the workflows | Version and checksum or digest |

## The supply-chain review

For each bump, read what changed upstream since the version you're
leaving: the release notes, and the diff where there is one. Look for:

- **new dependencies**, direct or pulled in;
- **new downloads**, at build time or at run time;
- **start-up scripts:** maintainer scripts, systemd units, init hooks,
  anything that runs on install or boot;
- **ownership changes:** new maintainers, a transferred repository, a
  new signing key, a different download host;
- **network calls** the thing didn't make before.

Then record a verdict:

- **clean:** you read it and found nothing of the above that worries
  you.
- **suspicious:** something there you can't explain. It **blocks the
  bump**: don't merge it, and the release check fails on it.
- **can't tell:** you couldn't review it well enough (a huge diff, a
  binary-only release). Say why, and what would settle it next time.

The review goes in the release's notes, `docs/releases/vX.Y.Z.md`, as
a table with a `Verdict` column under a `## Supply-chain review`
heading:

```markdown
## Supply-chain review

| Bump | From | To | Verdict | Notes |
|---|---|---|---|---|
| actions/runner | 2.338.2 | 2.339.0 | clean | Runner code only; no new dependencies |
| Ubuntu snapshot | 20261102T000000Z | 20261123T000000Z | clean | 41 packages moved, all security updates from noble-updates |
| Go modules | | | can't tell | golang.org/x/sys v0.38 to v0.40 is a 30k-line diff of generated code; spot-checked |
```

With nothing bumped, the section says `No bumps.` The check job reads
the `Verdict` column of every row: `clean` and `can't tell` pass, and
anything else, `suspicious` included, fails the release.

## If the key is compromised

Make a new key and set it up as above (a new commit to
`release-key.pub`, the variable, the secret), then release. Control
planes trust the key in their image unless their env file sets
`CREW_RELEASE_PUBLIC_KEY`, so an update moves them; boxes keep the key
they were installed with, so each needs `CREW_RELEASE_PUBLIC_KEY` in its
`agent/env` changed by hand, or a reprovision, before it takes another
agent update. Until then, pin every box to the agent it runs.
