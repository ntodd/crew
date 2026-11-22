// Physical mac-vz cache VM installation, recovery and cleanup.
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
//   E2E_MAC_CACHE_VM=1 E2E_AGENT_RELEASE_DIR=$PWD/tmp/dev-release \
//     npx playwright test tests/12-mac-cache-vm.spec.js
//
// Run on Apple silicon with room for the Flatcar downloads and sparse disks.
import {spawn, execFileSync} from "node:child_process"
import {chmodSync, existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"
import {expect, test} from "@playwright/test"
import {addBox, signIn} from "./helpers.js"

const repoRoot = resolve(import.meta.dirname, "../..")
const state = resolve(repoRoot, "tmp/mac-cache-vm-e2e")
const shims = resolve(state, "shims")
// Short: vfkit's REST socket lives in the box's directory, and Unix
// socket paths are capped at 104 bytes.
const root = "/private/tmp/cmv"
const hostvm = `${root}/Library/Application Support/Crew/hostvm`
const label = "com.crew.hostvm.cachevm"
const uid = process.getuid()
let launcher, tunnel

test.describe.configure({mode: "serial"})
test.skip(!process.env.E2E_MAC_CACHE_VM, "set E2E_MAC_CACHE_VM=1 (and see the header for the rest)")

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

test("a mac-vz box's cache VM installs, serves the Mac alone and restarts on request", async ({page, request}) => {
  test.setTimeout(1_800_000)
  setUp()
  await signIn(page)
  const token = await addBox(page, "m1-e2e", "mac-vz")
  const script = resolve(state, "mac-cache-vm.sh")
  writeFileSync(script, await (await request.get("/agent/mac-cache-vm.sh")).text())

  const cache = `${hostvm}/cachevm`
  const log = resolve(state, "cachevm.log")
  launcher = spawn("/bin/sh", ["-c", `exec sh "$0" --role cache --token "$1" >"$2" 2>&1`, script, token, log],
    {env: env(), stdio: "ignore", detached: true})
  const exited = new Promise(done => launcher.on("exit", code => done(code)))

  // Its first boot installs crew_cache from the control plane: the tunnel.
  await expect.poll(() => sshReady(cache), {timeout: 900_000, intervals: [5_000]}).toBe(true)
  openTunnel(cache)
  expect(await exited, readFileSync(log, "utf8")).toBe(0)
  const out = readFileSync(log, "utf8")
  expect(out).toContain("crew-box: cache ready")
  expect(out).toContain("crew-box: done: m1-e2e's cache VM is up")
  closeTunnel()

  // From the Mac: the cache, and management behind the token.
  const ip = address(cache)
  const mgmt = readFileSync(`${cache}/mgmt-token`, "utf8").trim()
  expect(await (await fetch(`http://${ip}/healthz`)).text()).toContain("ok")
  expect((await fetch(`http://${ip}:7780/host`)).status).toBe(401)
  const host = async () =>
    (await (await fetch(`http://${ip}:7780/host`, {headers: {authorization: `Bearer ${mgmt}`}})).json()).boot_id
  const boot = await host()
  expect(boot).toMatch(/^[0-9a-f-]{36}$/)
  expect(crewBox("status", "cachevm")).toContain("role:    cache")

  // The agent's request: launchd runs this when the file appears.
  const trigger = resolve(state, "restart-cachevm")
  writeFileSync(trigger, boot + "\n")
  crewBox("restart", "--role", "cache", "--trigger", trigger)
  expect(existsSync(trigger)).toBe(false)
  await expect.poll(async () => { try { return await host() } catch (_e) { return boot } },
    {timeout: 300_000, intervals: [5_000]}).not.toBe(boot)

  crewBox("uninstall", "--yes", "cachevm")
  expect(existsSync(cache)).toBe(false)
  expect(running(`vfkit.*${cache}/os.img`)).toBe(false)
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
  writeFileSync(resolve(shims, file), `#!/bin/sh\n# 12-mac-cache-vm.spec.js: running the launcher as you.\n${body}\n`)
  chmodSync(resolve(shims, file), 0o755)
}

function env() {
  return {...process.env, CREW_BOX_ROOT: root, PATH: `${shims}:/usr/bin:/bin:/usr/sbin:/sbin`}
}

function crewBox(...args) {
  return execFileSync(`${root}/usr/local/bin/crew-box`, args, {env: env(), encoding: "utf8", timeout: 180_000})
}

// The address vmnet's DHCP gave a VM, by the MAC in its box.conf.
function address(dir) {
  let conf
  try { conf = readFileSync(`${dir}/box.conf`, "utf8") } catch (_e) { return null }
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

function sshArgs(dir) {
  return ["-i", `${dir}/id_ed25519`, "-o", `UserKnownHostsFile=${state}/known_hosts`,
    "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]
}

function sshReady(dir) {
  const ip = address(dir)
  if (!ip || !existsSync(`${dir}/id_ed25519`)) return false
  // Bounded: ConnectTimeout covers connecting, not a box that hangs after.
  try { execFileSync("ssh", [...sshArgs(dir), `core@${ip}`, "true"], {stdio: "ignore", timeout: 15_000}); return true } catch (_e) { return false }
}

function openTunnel(dir) {
  closeTunnel()
  tunnel = spawn("ssh", [...sshArgs(dir), "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=10",
    "-R", "127.0.0.1:4100:127.0.0.1:4100", `core@${address(dir)}`], {stdio: "ignore"})
}

function closeTunnel() {
  if (tunnel && tunnel.exitCode === null) tunnel.kill("SIGTERM")
  tunnel = null
}
