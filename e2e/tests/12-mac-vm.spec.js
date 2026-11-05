// The mac-vm launcher, for real (§12.3): the control plane serves
// mac-vm.sh for a join token, and the script downloads vfkit and
// Flatcar, checks them against their pins, writes the box's disks,
// stages the Ignition with the image's own kernel, starts the box under
// launchd and follows its first boot until it enrolls. Then a job VM
// runs on the box under Firecracker (nested), and crew-box manages it:
// status, ssh, stop, start and uninstall.
//
// The launcher wants root and launchd's system domain. Here it runs as
// you: CREW_BOX_ROOT moves its paths under /private/tmp/cmv, and shims
// on PATH answer `id -u` with 0, skip `chown`, and send `launchctl`'s
// system domain to your GUI domain (gui/<uid>), with the box's root in
// the job's environment. vfkit, Flatcar, the disks, the staging boot and
// the box itself are the real ones. The control plane stays on
// loopback: the box reaches it through an SSH tunnel into the VM, opened
// once its sshd answers (as in 12-flatcar-box).
//
//   packaging/release/build-linux.sh linux-arm64 0.1.0 tmp/dev-release
//   (cd images/guest/tools && mix crew.sign ../../../tmp/dev-release)
//   make -C images/guest artifacts
//   E2E_MAC_VM=1 E2E_AGENT_RELEASE_DIR=$PWD/tmp/dev-release \
//     E2E_IMAGE_RELEASE_DIR=$PWD/images/guest/out/arm64/release \
//     npx playwright test tests/12-mac-vm.spec.js
//
// Needs macOS 15 or later on an M3 or later, about 1 GB of downloads,
// and 6 CPUs and 12 GiB for the box while it runs.
import {spawn, execFileSync} from "node:child_process"
import {chmodSync, existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"
import {expect, test} from "@playwright/test"
import {addBox, fakePost, fakeState, shot, signIn} from "./helpers.js"

const layer = "14-hardening"
const name = "mv-e2e"
const repoRoot = resolve(import.meta.dirname, "../..")
const state = resolve(repoRoot, "tmp/mac-vm-e2e")
const shims = resolve(state, "shims")
// Short: vfkit's REST socket lives in the box's directory, and Unix
// socket paths are capped at 104 bytes.
const root = "/private/tmp/cmv"
const hostvm = `${root}/Library/Application Support/Crew/hostvm`
const box = `${hostvm}/${name}`
const label = `com.crew.hostvm.${name}`
const uid = process.getuid()
let launcher, tunnel

test.describe.configure({mode: "serial"})
test.skip(!process.env.E2E_MAC_VM, "set E2E_MAC_VM=1 (and see the header for the rest)")

// After a failure too: the launcher, the box's launchd job, and any
// vfkit of this test's (the staging boot runs outside launchd). A guest
// that's stuck may ignore SIGTERM's power-off, so survivors get SIGKILL.
test.afterAll(async () => {
  // Hooks keep the 60 s default; this one may wait 90 s on launchd and
  // 30 s on vfkit before it kills.
  test.setTimeout(150_000)
  closeTunnel()
  if (launcher && launcher.exitCode === null) {
    try { process.kill(-launcher.pid, "SIGTERM") } catch (_e) {}
  }
  try { execFileSync("/bin/launchctl", ["bootout", `gui/${uid}/${label}`], {stdio: "ignore", timeout: 90_000}) } catch (_e) {}
  const ours = `vfkit.*${root}/`
  try { execFileSync("/usr/bin/pkill", ["-f", ours], {stdio: "ignore"}) } catch (_e) {}
  for (let i = 0; i < 30 && running(ours); i++) await new Promise(r => setTimeout(r, 1_000))
  try { execFileSync("/usr/bin/pkill", ["-9", "-f", ours], {stdio: "ignore"}) } catch (_e) {}
  if (launcher && launcher.exitCode === null) {
    try { process.kill(-launcher.pid, "SIGKILL") } catch (_e) {}
  }
})

function running(pattern) {
  try { execFileSync("/usr/bin/pgrep", ["-f", pattern], {stdio: "ignore"}); return true } catch (_e) { return false }
}

test("a mac-vm box installs, enrolls, runs a job VM and is managed with crew-box", async ({page, request}) => {
  test.setTimeout(2_700_000)
  setUp()
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["mv"]})

  const token = await addBox(page, name, "mac-vm")
  await expect(page.locator("#join-command")).toContainText("/agent/mac-vm.sh | sudo sh -s -- --token cj_")
  const script = resolve(state, "mac-vm.sh")
  writeFileSync(script, await (await request.get("/agent/mac-vm.sh")).text())

  // The one command, as the box page gives it (but for sudo).
  const log = resolve(state, "launcher.log")
  launcher = spawn("/bin/sh", ["-c", `exec sh "$0" --token "$1" --cpus 6 --memory 12 --data 100 >"$2" 2>&1`, script, token, log],
    {env: env(), stdio: "ignore", detached: true})
  const exited = new Promise(done => launcher.on("exit", code => done(code)))

  // Its first boot needs the control plane: the tunnel, once sshd answers.
  await expect.poll(() => sshReady(), {timeout: 900_000, intervals: [5_000]}).toBe(true)
  openTunnel()

  // The launcher follows the first boot until the box enrolls, then exits.
  expect(await exited, readFileSync(log, "utf8")).toBe(0)
  const out = readFileSync(log, "utf8")
  expect(out).toContain("crew-box: downloading vfkit")
  expect(out).toContain("crew-box: staging the config")
  expect(out).toContain("crew-box: enrolled")
  expect(out).toContain(`crew-box: done: ${name} is on the Boxes page in Crew`)

  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", {hasText: name})
  await expect(card).toContainText("Online", {timeout: 120_000})
  await card.click()
  await expect(page.locator("#capabilities")).toContainText("firecracker")
  await expect(page.locator("#capabilities")).toContainText("Firewall verified", {timeout: 120_000})
  await shot(page, layer, "mac-vm-box")

  // crew-box, as an admin on the Mac would use it.
  const status = crewBox("status")
  expect(status).toContain(`box:     ${name}`)
  expect(status).toContain("size:    6 CPUs, 12 GiB")
  expect(status).toContain(`launchd: loaded (${label})`)
  expect(status).toContain("vm:      Running")
  expect(status).toMatch(/address: \d+\.\d+\.\d+\.\d+/)
  expect(crewBox("ssh", name, "cat", "/etc/os-release")).toContain("Flatcar")
  // Nested virtualization reached the box: its job VMs need /dev/kvm.
  expect(crewBox("ssh", name, "test", "-c", "/dev/kvm", "&&", "echo", "kvm")).toContain("kvm")

  // A job VM under Firecracker, from the real guest image.
  await page.goto("/admin/images")
  await expect(page.locator("#rollout-arm64 li", {hasText: name})).toContainText("ready", {timeout: 600_000})
  const {jobs} = await fakePost(request, "/__fake/runs", {repo: "mona/mv", workflow: "On a mac-vm box", jobs: [{name: "mv", labels: ["crew-s"]}]})
  await expect.poll(async () => (await fakeState(request)).runners.find(r => r.labels.includes("crew-s"))?.name ?? "",
    {timeout: 120_000}).toMatch(/^crew-/)
  await openBox(page)
  const vms = page.locator("#vms")
  await expect(vms).toContainText("booted", {timeout: 180_000})
  await shot(page, layer, "mac-vm-box-vm")
  await fakePost(request, `/__fake/jobs/${jobs[0].id}`, {status: "completed", conclusion: "cancelled"})
  page.once("dialog", d => d.accept())
  await vms.locator("[id^=kill-]").first().click()
  await expect(vms).toContainText("No VMs.", {timeout: 120_000})

  // Stop: launchd unloads the job, vfkit asks the box to power off.
  closeTunnel()
  crewBox("stop", name)
  expect(crewBox("status")).toContain("launchd: not loaded")
  expect(vfkitRunning()).toBe(false)
  await openBox(page)
  await expect(page.locator("#box-status")).toContainText("Offline", {timeout: 120_000})

  // Start: the same disks, and the agent comes back on its own.
  crewBox("start", name)
  await expect.poll(() => sshReady(), {timeout: 300_000, intervals: [5_000]}).toBe(true)
  openTunnel()
  await expect(page.locator("#box-status")).toContainText("Online", {timeout: 300_000})
  await expect.poll(() => readFileSync(`${box}/serial.log`, "utf8"), {timeout: 60_000}).toMatch(/crew-box: agent started/)

  // Uninstall takes everything of the box's away, and crew-box with it.
  closeTunnel()
  crewBox("uninstall", "--yes", name)
  expect(existsSync(box)).toBe(false)
  expect(existsSync(`${root}/Library/LaunchDaemons/${label}.plist`)).toBe(false)
  expect(existsSync(`${root}/usr/local/bin/crew-box`)).toBe(false)
  expect(vfkitRunning()).toBe(false)
})

// The Mac's paths under CREW_BOX_ROOT, and the shims for running as you.
function setUp() {
  closeTunnel()
  try { execFileSync("/bin/launchctl", ["bootout", `gui/${uid}/${label}`], {stdio: "ignore"}) } catch (_e) {}
  rmSync(root, {recursive: true, force: true})
  rmSync(state, {recursive: true, force: true})
  mkdirSync(`${root}/Library/LaunchDaemons`, {recursive: true})
  mkdirSync(`${root}/var/db`, {recursive: true})
  symlinkSync("/var/db/dhcpd_leases", `${root}/var/db/dhcpd_leases`)
  mkdirSync(shims, {recursive: true})

  shim("id", `[ "$*" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"`)
  shim("chown", "exit 0")
  // launchd's system domain is root's: the user's GUI domain stands in,
  // and the job gets the box's root and these shims (launchd gives a
  // job no environment of its own).
  shim("launchctl", `uid=$(/usr/bin/id -u)
n=$#
for a in "$@"; do
  case $a in
    system) a=gui/$uid ;;
    system/*) a=gui/$uid/\${a#system/} ;;
    *.plist)
      e2e=\${a%.plist}.e2e.plist
      cp "$a" "$e2e" || exit 1
      /usr/bin/plutil -insert EnvironmentVariables -json "{\\"CREW_BOX_ROOT\\":\\"$CREW_BOX_ROOT\\",\\"PATH\\":\\"$PATH\\"}" "$e2e" || exit 1
      a=$e2e ;;
  esac
  set -- "$@" "$a"
done
shift $n
exec /bin/launchctl "$@"`)
}

function shim(file, body) {
  writeFileSync(resolve(shims, file), `#!/bin/sh\n# 12-mac-vm.spec.js: running the launcher as you.\n${body}\n`)
  chmodSync(resolve(shims, file), 0o755)
}

function env() {
  return {...process.env, CREW_BOX_ROOT: root, PATH: `${shims}:/usr/bin:/bin:/usr/sbin:/sbin`}
}

function crewBox(...args) {
  return execFileSync(`${root}/usr/local/bin/crew-box`, args, {env: env(), encoding: "utf8", timeout: 180_000})
}

async function openBox(page) {
  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: name}).click()
}

function vfkitRunning() {
  return running(`vfkit.*${box}/os.img`)
}

// The address vmnet's DHCP gave the box, by the MAC in its box.conf.
function address() {
  let conf
  try { conf = readFileSync(`${box}/box.conf`, "utf8") } catch (_e) { return null }
  const mac = (conf.match(/^mac=(.*)$/m) || [])[1]
  if (!mac) return null
  const short = mac.split(":").map(p => p.replace(/^0(.)/, "$1")).join(":")
  let leases = ""
  try { leases = readFileSync("/var/db/dhcpd_leases", "utf8") } catch (_e) { return null }
  let found = null
  for (const block of leases.split("}")) {
    if (block.includes(`hw_address=1,${short}`)) found = (block.match(/ip_address=([0-9.]+)/) || [])[1] || found
  }
  return found
}

function sshArgs() {
  return ["-i", `${box}/id_ed25519`, "-o", `UserKnownHostsFile=${state}/known_hosts`,
    "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]
}

function sshReady() {
  const ip = address()
  if (!ip || !existsSync(`${box}/id_ed25519`)) return false
  // Bounded: ConnectTimeout covers connecting, not a box that hangs after.
  try { execFileSync("ssh", [...sshArgs(), `core@${ip}`, "true"], {stdio: "ignore", timeout: 15_000}); return true } catch (_e) { return false }
}

function openTunnel() {
  closeTunnel()
  tunnel = spawn("ssh", [...sshArgs(), "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=10",
    "-R", "127.0.0.1:4100:127.0.0.1:4100", `core@${address()}`], {stdio: "ignore"})
}

function closeTunnel() {
  if (tunnel && tunnel.exitCode === null) tunnel.kill("SIGTERM")
  tunnel = null
}
