// Scheduling end to end (§8, §23): two null-driver boxes, 30 jobs over
// three sizes. Crew registers JIT runners with the fake GitHub, boots a
// VM per runner, the fake GitHub assigns each runner a job, and the
// fake guest runs it and powers off. Every job must succeed, on a Crew
// VM, with no VM left behind.
import { expect, test } from "@playwright/test"
import { addBox, fakePost, fakeState, shot, signIn, startAgent, stopAgent } from "./helpers.js"

const layer = "05-scheduler"
const repo = "mona/sched"
const agents = []

test.describe.configure({ mode: "serial" })
test.afterAll(() => agents.forEach(stopAgent))

async function onlineBox(page, name) {
  const token = await addBox(page, name)
  agents.push(startAgent(token, { name }))
  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", { hasText: name })).toContainText("Online", { timeout: 180_000 })
}

const jobsOf = (state, runId) => state.jobs.filter(j => j.run_id === runId)

test("30 jobs over 3 sizes run on 2 boxes", async ({ page, request }) => {
  test.setTimeout(420_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", { names: ["sched"] })
  await onlineBox(page, "null-a")
  await onlineBox(page, "null-b")

  const sizes = ["crew-s", "crew-m", "crew-l"]
  const specs = Array.from({ length: 30 }, (_, i) => ({
    name: `job ${String(i + 1).padStart(2, "0")}`,
    labels: [sizes[i % 3]],
    seconds: 3 + (i % 4),
  }))
  const { run } = await fakePost(request, "/__fake/runs", { repo, workflow: "Matrix", message: "Run the matrix", jobs: specs })

  // Mid-run: VMs on the box page, and jobs running or waiting with a reason.
  const box = page.locator("[id^=box-]", { hasText: "null-a" })
  await page.goto("/boxes")
  await box.click()
  await expect(page.locator("#vms li[id^=vm-]").first()).toBeVisible({ timeout: 60_000 })
  await expect(page.locator("#vms")).toContainText("busy", { timeout: 60_000 })
  await expect(page.locator("#allocation")).not.toContainText(/^0 of/)
  await shot(page, layer, "box-busy")

  await page.goto("/runs")
  await page.locator(`#run-${run.id}`).getByRole("link", { name: /Matrix/ }).click()
  await page.waitForURL(/\/runs\/\d+\/attempts\/1/)
  await expect(page.locator("[id^=job-] [data-job-state=running]").first()).toBeVisible({ timeout: 30_000 })
  await shot(page, layer, "run-in-progress")

  // Every job finishes, each on a runner Crew registered.
  await expect
    .poll(async () => jobsOf(await fakeState(request), run.id).filter(j => j.status === "completed").length, {
      timeout: 300_000,
      intervals: [2_000],
    })
    .toBe(30)

  const state = await fakeState(request)
  const jobs = jobsOf(state, run.id)
  expect(jobs.every(j => j.conclusion === "success")).toBe(true)
  expect(jobs.every(j => /^crew-[a-z0-9]{4}-null-[ab]-[0-9a-f]{10}$/.test(j.runner_name))).toBe(true)
  expect(new Set(jobs.map(j => j.runner_name)).size).toBe(30)
  // Both boxes took work.
  expect(new Set(jobs.map(j => j.runner_name.match(/null-[ab]/)[0])).size).toBe(2)
  // JIT runners are ephemeral: none is left registered.
  await expect.poll(async () => (await fakeState(request)).runners.length, { timeout: 60_000 }).toBe(0)

  await expect(page.locator("[data-job-state=success]")).toHaveCount(30, { timeout: 30_000 })
  await shot(page, layer, "run-done")

  // No VM is left: everything was destroyed once its guest powered off.
  await page.goto("/boxes")
  await box.click()
  await expect(page.locator("#vms")).toContainText("No VMs.", { timeout: 60_000 })
  await expect(page.locator("#allocation")).toContainText(/^\s*0 of/)
  await shot(page, layer, "box-idle")
})

test("a job cancelled while queued gets no runner, and spare VMs are reaped", async ({ page, request }) => {
  test.setTimeout(180_000)
  await signIn(page)
  const { run, jobs } = await fakePost(request, "/__fake/runs", {
    repo,
    workflow: "Cancel",
    jobs: [{ name: "held", labels: ["crew-xl"], hold: true }],
  })

  // Crew boots a runner for it; GitHub never assigns the held job.
  await page.goto("/boxes")
  await page.locator("[id^=box-]", { hasText: /null-[ab]/ }).first().click()
  await expect.poll(async () => (await fakeState(request)).runners.length, { timeout: 60_000 }).toBe(1)

  // Cancelled while queued: demand drops, so the idle VM is excess and is
  // reaped once idle_grace (30 s) has passed.
  await fakePost(request, `/__fake/jobs/${jobs[0].id}`, { status: "completed", conclusion: "cancelled" })
  await expect.poll(async () => (await fakeState(request)).runners.length, { timeout: 90_000 }).toBe(0)

  await page.goto("/runs")
  await page.locator(`#run-${run.id}`).getByRole("link", { name: /Cancel/ }).click()
  await expect(page.locator(`#job-${jobs[0].id}`)).toContainText("Cancelled")
  await shot(page, layer, "cancelled")
})
