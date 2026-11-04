// The pages of layer 8 (§17.3) in a real browser, under production's
// style policy (CREW_STRICT_CSP=1): the dashboard, the queue, the stack
// view, a run's actions and jobs table, a box's controls, and Sizes &
// labels. No page may trip the CSP.
import {expect, test} from "@playwright/test"
import {addBox, fakePost, fakeState, setTheme, shot, signIn, startAgent, stopAgent} from "./helpers.js"

const layer = "08-ui"
let agent
const violations = []

test.describe.configure({mode: "serial"})
test.afterAll(() => stopAgent(agent))
test.beforeEach(({page}) => {
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(`${page.url()}: ${m.text()}`)
  })
})
test.afterEach(() => expect(violations).toEqual([]))

test("the dashboard, with a box and work", async ({page, request}) => {
  test.setTimeout(240_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["ui"]})
  const token = await addBox(page, "null-ui")
  agent = startAgent(token, {name: "null-ui"})
  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", {hasText: "null-ui"})).toContainText("Online", {timeout: 180_000})

  // Some finished work, and a job that waits (a size no box can hold).
  await fakePost(request, "/__fake/runs", {repo: "mona/ui", workflow: "Build", branch: "feat/one", sha: "a".repeat(40), jobs: [{name: "unit", labels: ["crew-s"], seconds: 2}]})
  await fakePost(request, "/__fake/runs", {repo: "mona/ui", workflow: "Build", branch: "feat/one", sha: "b".repeat(40), jobs: [{name: "unit", labels: ["crew-s"], seconds: 2}, {name: "e2e (1)", labels: ["crew-s"], seconds: 3}, {name: "e2e (2)", labels: ["crew-s"], seconds: 3}]})
  await fakePost(request, "/__fake/runs", {repo: "mona/ui", workflow: "Release", branch: "main", jobs: [{name: "huge", labels: ["crew-xl"], hold: true}]})
  await expect.poll(async () => (await fakeState(request)).jobs.filter(j => j.status === "completed").length, {timeout: 120_000}).toBeGreaterThanOrEqual(4)

  await page.goto("/")
  await expect(page.locator("#fleet")).toContainText("null-ui")
  await expect(page.locator("#counters")).toContainText("Waiting")
  await expect(page.locator("#recent li").first()).toBeVisible()
  await expect(page.locator("#chart-started")).toBeVisible()
  await shot(page, layer, "dashboard")
  await setTheme(page, "dark")
  await shot(page, layer, "dashboard-dark")
  await setTheme(page, "light")
})

test("the queue", async ({page}) => {
  await signIn(page)
  await page.goto("/queue")
  await expect(page.locator("#units")).toContainText("huge")
  await expect(page.locator("#classes")).toContainText("crew-xl")
  await expect(page.locator("#queue-chart")).toBeVisible()
  await shot(page, layer, "queue")
  await page.setViewportSize({width: 360, height: 800})
  await page.goto("/queue")
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  await shot(page, layer, "queue-mobile")
})

test("runs by branch, and a run's actions and jobs", async ({page, request}) => {
  await signIn(page)
  await page.goto("/runs")
  await page.locator("#view-stack").click()
  await expect(page).toHaveURL(/view=stack/)
  const feat = page.locator("[data-branch=\"feat/one\"]")
  await expect(feat.locator("details[data-superseded] summary")).toContainText("1 superseded")
  await shot(page, layer, "runs-stack")

  // The finished run with matrix jobs.
  const run = (await fakeState(request)).runs.find(r => r.head_sha === "b".repeat(40))
  await page.goto(`/runs/${run.id}/attempts/1`)
  await expect(page.locator("[id^=group-e2e]")).toContainText("e2e (1)")
  await expect(page.locator("#rerun-all")).toBeVisible()
  await shot(page, layer, "run")

  // The held run can be cancelled.
  const held = (await fakeState(request)).runs.find(r => r.name === "Release")
  await page.goto(`/runs/${held.id}/attempts/1`)
  page.once("dialog", d => d.accept())
  await page.locator("#cancel-run").click()
  await expect(page.getByText("Cancelling the run")).toBeVisible()
  await expect.poll(async () => (await fakeState(request)).cancelled).toContain(held.id)
})

test("a box's controls", async ({page}) => {
  await signIn(page)
  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: "null-ui"}).click()
  await expect(page.locator("#images")).toContainText("0.0.0-dev")
  await expect(page.locator("#capacity")).toBeVisible()
  page.once("dialog", d => d.accept())
  await page.locator("#drain").click()
  await expect(page.locator("#box-status")).toContainText("Draining")
  await shot(page, layer, "box-controls")
  await page.locator("#undrain").click()
  await expect(page.locator("#drain")).toBeVisible()
})

test("Sizes & labels, and the label tester", async ({page}) => {
  await signIn(page)
  await page.goto("/admin/sizes")
  await page.locator("input[name=runs_on]").fill("[self-hosted, crew-l-arm64]")
  await expect(page.locator("#tested")).toContainText("Crew job")
  await expect(page.locator("#tested")).toContainText("null-ui")
  await page.locator("input[name=runs_on]").fill('["self-hosted", "crew-m"]')
  await expect(page.locator("#tested")).toContainText("Crew job: size m")
  await shot(page, layer, "sizes")

  // Phone-wide, the sizes fit without scrolling sideways.
  await page.setViewportSize({width: 360, height: 800})
  await page.goto("/admin/sizes")
  await expect(page.locator("#sizes")).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  await shot(page, layer, "sizes-mobile")
})
