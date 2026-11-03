// A Crew job on a real VM (§11.4): a box on the vz driver, crew-vzd and
// its helper booting crew-vz's test guest under Virtualization.framework.
// The guest's crew mode walks the guest API from inside the VM; GitHub's
// side (assigning the job to the runner, completing it) is the fake's,
// driven here. Needs the binary and the guest, so it runs only with
// E2E_VZ=1:
//
//   (cd native && make && make guest) && E2E_VZ=1 npx playwright test tests/06-vz.spec.js
import { spawn } from "node:child_process"
import { existsSync, mkdirSync, rmSync } from "node:fs"
import { resolve } from "node:path"
import { expect, test } from "@playwright/test"
import { addBox, fake, fakePost, fakeState, shot, signIn, startAgent, stopAgent } from "./helpers.js"

const layer = "06-vz-driver"
const root = resolve(import.meta.dirname, "../..")
const bin = resolve(root, "native/crew-vz/bin/crew-vz")
const guest = resolve(root, "tmp/crew-vz-guest")
// Short: Unix socket paths are capped at 104 bytes on macOS.
const dir = "/private/tmp/crew-e2e-vz"
let daemon, agent

test.describe.configure({ mode: "serial" })
test.skip(!process.env.E2E_VZ, "set E2E_VZ=1 (needs native/crew-vz/bin/crew-vz and tmp/crew-vz-guest)")

test.beforeAll(() => {
  if (!existsSync(bin) || !existsSync(resolve(guest, "rootfs.ext4"))) throw new Error("build native/ and the guest first")
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(resolve(dir, "vms"), { recursive: true })
  // Under the helper sandbox, as a box runs it (§11.4).
  const sandbox = resolve(root, "native/crew-vz/sandbox.sb")
  daemon = spawn(bin, ["daemon", "--socket", `${dir}/vzd.sock`, "--data-dir", dir, "--sandbox", sandbox], { stdio: "ignore", detached: true })
})

test.afterAll(() => {
  stopAgent(agent)
  try { process.kill(-daemon.pid, "SIGTERM") } catch (_e) {}
})

test("a job runs on a real VM", async ({ page, request }) => {
  test.setTimeout(240_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", { names: ["vz"] })

  const token = await addBox(page, "m4-vz")
  agent = startAgent(token, {
    name: "m4-vz",
    dataDir: dir,
    keepDir: true,
    env: {
      CREW_DRIVER: "vz",
      CREW_VZD_SOCKET: `${dir}/vzd.sock`,
      CREW_VZ_BIN: bin,
      CREW_DEV_IMAGE_DIR: guest,
      CREW_VZ_DNS_FALLBACK: "1.1.1.1",
    },
  })

  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", { hasText: "m4-vz" })
  await expect(card).toContainText("Online", { timeout: 180_000 })
  await expect(card).toContainText("vz")
  await card.click()
  await expect(page.locator("#capabilities")).toContainText("vz")
  await expect(page.locator("#capabilities")).toContainText("Firewall verified")

  const { run, jobs } = await fakePost(request, "/__fake/runs", {
    repo: "mona/vz",
    workflow: "On a Mac VM",
    message: "Boot a real VM",
    jobs: [{ name: "real vm", labels: ["crew-s"] }],
  })

  // Crew registers a JIT runner and boots a VM for it; the guest fetches
  // its payload and listens.
  const ours = state => state.runners.find(r => r.labels.includes("crew-s"))
  await expect
    .poll(async () => ours(await fakeState(request))?.name ?? "", { timeout: 60_000 })
    .toMatch(/^crew-[a-z0-9]{4}-m4-vz-[0-9a-f]{10}$/)
  const runner = ours(await fakeState(request)).name

  await expect(page.locator("#vms")).toContainText(runner, { timeout: 60_000 })
  await expect(page.locator("#vms")).toContainText("idle", { timeout: 60_000 })
  await shot(page, layer, "box-idle-vm")

  // GitHub gives the runner the job.
  const assigned = await (await request.get(`${fake}/__fake/runners/${runner}/job?wait=5`)).json()
  expect(assigned.id).toBe(jobs[0].id)
  await expect(page.locator("#vms")).toContainText("busy", { timeout: 30_000 })
  await shot(page, layer, "box-busy-vm")

  await page.goto("/runs")
  await page.locator(`#run-${run.id}`).getByRole("link", { name: /On a Mac VM/ }).click()
  await page.waitForURL(/\/runs\/\d+\/attempts\/1/)
  await expect(page.locator(`#job-${jobs[0].id} [data-job-state=running]`)).toBeVisible()
  await shot(page, layer, "run-on-vz")

  // Done: the VM gets its graceful stop after the log-flush grace (30 s),
  // powers off through the power button, and is destroyed.
  await fakePost(request, `/__fake/runners/${runner}/done`, { conclusion: "success" })
  await expect(page.locator(`#job-${jobs[0].id} [data-job-state=success]`)).toBeVisible({ timeout: 30_000 })

  await page.goto("/boxes")
  await card.click()
  await expect(page.locator("#vms")).toContainText("No VMs.", { timeout: 90_000 })
  await expect(page.locator("#operations")).toContainText("Stop a VM")
  await shot(page, layer, "box-after")
})
