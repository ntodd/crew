// A Linux box on Flatcar, for real (§12): the control plane renders the
// box's Ignition for a join token, a Flatcar VM with nested
// virtualization boots it on this Mac (native/hostvm-dev, through
// e2e/hostvm/up.sh), installs the signed agent and cache tarballs from
// the control plane, enrolls, and runs a job VM under Firecracker from
// the real guest image. The control plane stays on loopback: the box
// reaches it through an SSH tunnel into the VM (its 127.0.0.1:4100),
// opened once the VM's sshd answers. Needs a lot, so it runs only with
// E2E_FLATCAR=1:
//
//   make -C native hostvm-dev
//   packaging/release/build-linux.sh linux-arm64 0.1.0 tmp/dev-release
//   (cd images/guest/tools && mix crew.sign ../../../tmp/dev-release)
//   E2E_FLATCAR=1 E2E_AGENT_RELEASE_DIR=$PWD/tmp/dev-release \
//     E2E_IMAGE_RELEASE_DIR=$PWD/images/guest/out/arm64/release \
//     npx playwright test tests/12-flatcar-box.spec.js
import {spawn, execFileSync} from "node:child_process"
import {mkdirSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"
import {expect, test} from "@playwright/test"
import {addBox, fakePost, fakeState, shot, signIn} from "./helpers.js"

const layer = "12-flatcar"
const root = resolve(import.meta.dirname, "../..")
const state = resolve(root, "tmp/hostvm-e2e")
const mac = "52:54:00:c7:e0:02"
let vm, tunnel

test.describe.configure({mode: "serial"})
test.skip(!process.env.E2E_FLATCAR, "set E2E_FLATCAR=1 (and see the header for the rest)")

test.afterAll(() => {
  if (tunnel && tunnel.exitCode === null) tunnel.kill("SIGTERM")
  if (vm && vm.exitCode === null) {
    try { process.kill(-vm.pid, "SIGTERM") } catch (_e) {}
  }
})

test("a Flatcar box enrolls and runs a job VM under Firecracker", async ({page, request}) => {
  test.setTimeout(1_800_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["fc"]})

  const token = await addBox(page, "fc-e2e", "mac-vm")
  await shot(page, layer, "add-mac-vm")

  rmSync(state, {recursive: true, force: true})
  mkdirSync(state, {recursive: true})
  execFileSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", resolve(state, "id_ed25519")])
  const resp = await request.post("/agent/flatcar/ignition", {
    form: {join_token: token, arch: "arm64", "ssh_keys[]": readFileSync(resolve(state, "id_ed25519.pub"), "utf8").trim()},
  })
  expect(resp.status()).toBe(200)
  expect(resp.headers()["x-crew-box"]).toBe("fc-e2e")
  writeFileSync(resolve(state, "box.ign"), await resp.body(), {mode: 0o600})

  vm = spawn(resolve(root, "e2e/hostvm/up.sh"), [], {
    env: {...process.env, HOSTVM_DIR: state, HOSTVM_IGNITION: resolve(state, "box.ign"), HOSTVM_MAC: mac,
      HOSTVM_CPUS: "6", HOSTVM_MEMORY_MIB: "12288"},
    stdio: "ignore",
    detached: true,
  })

  // The box's way to the control plane, once its sshd answers.
  await expect.poll(() => sshReady(), {timeout: 600_000, intervals: [5_000]}).toBe(true)
  tunnel = spawn("ssh", [...sshArgs(), "-N", "-o", "ExitOnForwardFailure=yes", "-R", "127.0.0.1:4100:127.0.0.1:4100", `core@${address()}`],
    {stdio: "ignore"})

  // First boot: Ignition, the data disk, the tarballs, enrollment.
  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", {hasText: "fc-e2e"})
  await expect(card).toContainText("Online", {timeout: 900_000})
  await card.click()
  await expect(page.locator("#capabilities")).toContainText("firecracker")
  // The first verdict comes before the box learns its egress address.
  await expect(page.locator("#capabilities")).toContainText("Firewall verified", {timeout: 120_000})
  await shot(page, layer, "flatcar-box")

  // The real guest image, prepared on the box from the control plane.
  await page.goto("/admin/images")
  await expect(page.locator("#rollout-arm64")).toContainText("fc-e2e")
  await expect(page.locator("#rollout-arm64 li", {hasText: "fc-e2e"})).toContainText("ready", {timeout: 600_000})

  // A job: a Firecracker VM boots, and crew-guest fetches its payload.
  const {jobs} = await fakePost(request, "/__fake/runs", {repo: "mona/fc", workflow: "On Firecracker", jobs: [{name: "fc", labels: ["crew-s"]}]})
  await expect.poll(async () => (await fakeState(request)).runners.find(r => r.labels.includes("crew-s"))?.name ?? "", {timeout: 120_000}).toMatch(/^crew-/)
  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: "fc-e2e"}).click()
  const vms = page.locator("#vms")
  await expect(vms).toContainText("booted", {timeout: 180_000})
  await shot(page, layer, "flatcar-box-vm")

  await fakePost(request, `/__fake/jobs/${jobs[0].id}`, {status: "completed", conclusion: "cancelled"})
  page.once("dialog", d => d.accept())
  await vms.locator("[id^=kill-]").first().click()
  await expect(vms).toContainText("No VMs.", {timeout: 120_000})
})

// The address vmnet's DHCP gave the box, by its MAC (as the launchers find it).
function address() {
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
  return ["-i", resolve(state, "id_ed25519"), "-o", `UserKnownHostsFile=${resolve(state, "known_hosts")}`,
    "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]
}

function sshReady() {
  const ip = address()
  if (!ip) return false
  try { execFileSync("ssh", [...sshArgs(), `core@${ip}`, "true"], {stdio: "ignore"}); return true } catch (_e) { return false }
}
