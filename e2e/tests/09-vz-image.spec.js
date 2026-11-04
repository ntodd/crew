// The real guest image on a real VM (§13.1): the control plane registers
// a built release (signed with the development key), a vz box downloads
// it from the control plane, checks it against the signed manifest,
// decompresses it, and boots a job VM from it, whose crew-guest fetches
// its payload from the agent. GitHub's side is the fake, which the real
// actions/runner can't talk to, so the test stops the VM once crew-guest
// is up. Needs the build and the binary:
//
//   make -C images/guest && (cd native && make)
//   E2E_VZ=1 E2E_IMAGE_RELEASE_DIR=$PWD/images/guest/out/arm64/release \
//     npx playwright test tests/09-vz-image.spec.js
import {spawn} from "node:child_process"
import {existsSync, mkdirSync, rmSync} from "node:fs"
import {resolve} from "node:path"
import {expect, test} from "@playwright/test"
import {addBox, fakePost, fakeState, shot, signIn, startAgent, stopAgent} from "./helpers.js"

const layer = "09-guest-image"
const root = resolve(import.meta.dirname, "../..")
const bin = resolve(root, "native/crew-vz/bin/crew-vz")
const dir = "/private/tmp/crew-e2e-img"
let daemon, agent

test.describe.configure({mode: "serial"})
test.skip(!process.env.E2E_VZ || !process.env.E2E_IMAGE_RELEASE_DIR, "set E2E_VZ=1 and E2E_IMAGE_RELEASE_DIR")

test.beforeAll(() => {
  if (!existsSync(bin)) throw new Error("build native/ first")
  rmSync(dir, {recursive: true, force: true})
  mkdirSync(resolve(dir, "vms"), {recursive: true})
  const sandbox = resolve(root, "native/crew-vz/sandbox.sb")
  daemon = spawn(bin, ["daemon", "--socket", `${dir}/vzd.sock`, "--data-dir", dir, "--sandbox", sandbox], {stdio: "ignore", detached: true})
})

test.afterAll(() => {
  stopAgent(agent)
  try { process.kill(-daemon.pid, "SIGTERM") } catch (_e) {}
})

test("a box prepares the real image and boots a job VM from it", async ({page, request}) => {
  test.setTimeout(900_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["img"]})

  const token = await addBox(page, "m4-img")
  const pub = (await import("node:fs")).readFileSync(resolve(root, "images/guest/keys/test-signing.pub"), "utf8")
  agent = startAgent(token, {
    name: "m4-img",
    dataDir: dir,
    keepDir: true,
    env: {
      CREW_DRIVER: "vz",
      CREW_VZD_SOCKET: `${dir}/vzd.sock`,
      CREW_VZ_BIN: bin,
      CREW_VZ_DNS_FALLBACK: "1.1.1.1",
      CREW_RELEASE_PUBLIC_KEY: pub.split("\n").filter(l => l && !l.startsWith("#")).join(""),
    },
  })

  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", {hasText: "m4-img"})).toContainText("Online", {timeout: 180_000})

  // Download (734 MB from the control plane), verify, decompress (4 GiB).
  await page.goto("/admin/images")
  const rollout = page.locator("#rollout-arm64")
  await expect(rollout).toContainText("m4-img")
  await expect(rollout).toContainText(/downloading|verifying|converting|ready/, {timeout: 60_000})
  await shot(page, layer, "images-preparing")
  const started = Date.now()
  await expect(rollout).toContainText("ready", {timeout: 600_000})
  console.log(`prepared in ${Math.round((Date.now() - started) / 1000)} s`)
  await shot(page, layer, "images-ready")

  // A job: a VM boots from the image, and crew-guest fetches its payload.
  const {jobs} = await fakePost(request, "/__fake/runs", {repo: "mona/img", workflow: "On the real image", jobs: [{name: "real image", labels: ["crew-s"]}]})
  const ours = state => state.runners.find(r => r.labels.includes("crew-s"))
  await expect.poll(async () => ours(await fakeState(request))?.name ?? "", {timeout: 60_000}).toMatch(/^crew-/)
  const runner = ours(await fakeState(request)).name

  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: "m4-img"}).click()
  const vms = page.locator("#vms")
  await expect(vms).toContainText(runner, {timeout: 60_000})
  // "booted" is the agent's: crew-guest fetched its payload.
  await expect(vms).toContainText("booted", {timeout: 120_000})
  await shot(page, layer, "box-real-image-vm")

  // The fake can't serve the real runner: the job is cancelled, so no
  // other VM is placed for it, and this one is stopped.
  await fakePost(request, `/__fake/jobs/${jobs[0].id}`, {status: "completed", conclusion: "cancelled"})
  page.once("dialog", d => d.accept())
  await vms.locator("[id^=kill-]").first().click()
  await expect(vms).toContainText("No VMs.", {timeout: 120_000})
})
