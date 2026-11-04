// Live logs and the job page (§16, §17.6): a job on a null-driver box
// writes a rich log (groups, colours, annotations, 20,000 filler lines)
// through the guest API; the job page shows it live, virtualised, and
// switches to GitHub's log when the job is done.
import {expect, test} from "@playwright/test"
import {addBox, fakePost, fakeState, shot, signIn, startAgent, stopAgent} from "./helpers.js"

const layer = "07-live-logs"
const repo = "mona/logs"
let agent

test.describe.configure({mode: "serial"})
test.afterAll(() => stopAgent(agent))

async function ensureBox(page) {
  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", {hasText: "null-logs"})
  if (!(await card.count())) {
    const token = await addBox(page, "null-logs")
    agent = startAgent(token, {name: "null-logs"})
  }
  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", {hasText: "null-logs"})).toContainText("Online", {timeout: 180_000})
}

async function openJob(page, run, job) {
  await page.goto(`/runs/${run.id}/attempts/1/jobs/${job.id}`)
  await expect(page.locator("#log-viewer .lv-scroller")).toBeVisible()
}

test("a running job's log, live", async ({page, request}) => {
  test.setTimeout(300_000)
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["logs"]})
  await ensureBox(page)

  const {run, jobs} = await fakePost(request, "/__fake/runs", {
    repo,
    workflow: "Logs",
    jobs: [{name: "rich", labels: ["crew-s"], seconds: 25, exit: 1, log: "rich", log_lines: 20000}],
  })
  const job = jobs[0]

  await expect.poll(async () => (await fakeState(request)).jobs.find(j => j.id === job.id).status, {timeout: 90_000}).toBe("in_progress")

  // From the run page to the job.
  await page.goto(`/runs/${run.id}/attempts/1`)
  await page.getByRole("link", {name: "rich"}).click()
  await page.waitForURL(new RegExp(`/jobs/${job.id}$`))
  const viewer = page.locator("#log-viewer")
  await expect(viewer.locator(".lv-line").first()).toBeVisible({timeout: 30_000})
  await expect(page.locator("#log-source")).toContainText("Reported by the VM")

  // The whole log arrives (about 20,000 lines) and only a window is in the DOM.
  await expect.poll(async () => Number(await viewer.locator(".lv-line .lv-ln").last().textContent()), {timeout: 60_000}).toBeGreaterThan(20000)
  expect(await viewer.locator(".lv-line").count()).toBeLessThan(700)

  // Follow mode keeps the newest line in view; scrolling up pauses it and
  // new lines show the pill.
  await expect(viewer.locator(".lv-line", {hasText: /tick \d+/}).last()).toBeVisible({timeout: 20_000})
  await shot(page, layer, "job-live")
  await viewer.locator(".lv-scroller").evaluate(s => s.scrollBy(0, -4000))
  await expect(viewer.locator(".lv-pill")).toBeVisible({timeout: 10_000})
  await expect(viewer.locator(".lv-pill")).toContainText(/Jump to live \(\d+ new\)/)
  await shot(page, layer, "job-paused")
  await viewer.locator(".lv-pill").click()
  await expect(viewer.locator(".lv-pill")).toBeHidden()

  // The top of the log: the group starts collapsed (finished step? no:
  // the step is running, so it's open), colours as classes, text as text.
  await page.keyboard.press("g")
  await expect(viewer.locator(".lv-line[data-n='1']")).toBeVisible()
  const group = viewer.locator(".lv-group", {hasText: "Install dependencies"})
  await expect(group).toBeVisible()
  await expect(viewer.locator(".lv-line", {hasText: "fetched package 3"})).toBeVisible()
  await group.locator(".lv-caret").click()
  await expect(viewer.locator(".lv-line", {hasText: "fetched package 3"})).toHaveCount(0)
  await group.locator(".lv-caret").click()
  await expect(viewer.locator(".fg-2", {hasText: "green"}).first()).toBeVisible()
  await expect(viewer.locator(".b.fg-1", {hasText: "bold red"})).toBeVisible()
  // <b> stays text, and URLs aren't linked.
  const plain = viewer.locator(".lv-line", {hasText: "not bold"})
  await expect(plain).toContainText("<b>not bold</b>")
  await expect(plain.locator("b, a")).toHaveCount(0)

  // Annotations: badges, a summary bar, and a link built only as a GitHub blob URL.
  await expect(viewer.locator(".lv-annotations")).toContainText("1 warning")
  const warning = viewer.locator(".lv-line.lv-warning")
  await expect(warning.locator(".lv-badge")).toHaveText("warning")
  await expect(warning.locator("a.lv-file")).toHaveAttribute("href", /^http:\/\/localhost:4199\/mona\/logs\/blob\/[0-9a-f]+\/lib\/app\.ex#L3$/)

  // Search, on the server: hits, a counter, Enter steps through.
  await page.keyboard.press("/")
  await page.locator(".lv-search").fill("needle")
  await page.keyboard.press("Enter")
  await expect(viewer.locator(".lv-counter")).toHaveText("1 / 1")
  await expect(viewer.locator(".lv-hit-current", {hasText: "needle"})).toBeVisible()
  await page.locator(".lv-search").fill("filler line 1999")
  await page.keyboard.press("Enter")
  await expect(viewer.locator(".lv-counter")).toHaveText(/1 \/ \d+/)
  await expect(viewer.locator(".lv-hit-current")).toContainText("filler line 1999")

  // Line links.
  const ln = viewer.locator(".lv-hit-current .lv-ln")
  const n = await ln.textContent()
  await ln.click()
  await expect(page).toHaveURL(new RegExp(`#L${n}$`))
  await expect(viewer.locator(".lv-selected .lv-ln")).toHaveText(n)

  // Timestamps and wrap.
  await page.locator(".lv-scroller").focus()
  await page.keyboard.press("t")
  await expect(viewer.locator(".lv-ts").first()).toHaveText(/^\d\d:\d\d:\d\d\.\d{3}$/)
  await page.keyboard.press("w")
  await expect(viewer).toHaveClass(/lv-wrap/)
  await shot(page, layer, "job-search")

  // Keys help.
  await page.keyboard.press("?")
  await expect(viewer.locator(".lv-help")).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(viewer.locator(".lv-help")).toBeHidden()
})

test("a finished job shows GitHub's log, and its first error", async ({page, request}) => {
  test.setTimeout(240_000)
  await signIn(page)
  const run = (await fakeState(request)).runs.find(r => r.name === "Logs")
  const job = (await fakeState(request)).jobs.find(j => j.run_id === run.id)
  await expect.poll(async () => (await fakeState(request)).jobs.find(j => j.id === job.id).status, {timeout: 120_000}).toBe("completed")

  await openJob(page, run, job)
  // GitHub's log is fetched 5 s after completed.
  await expect(page.locator("#log-source")).toContainText("GitHub's log (authoritative)", {timeout: 30_000})
  const viewer = page.locator("#log-viewer")
  await expect(viewer.locator(".lv-line").first()).toBeVisible()
  await expect(page.locator("#steps")).toContainText("Set up job")
  await expect(page.locator("#steps")).toContainText("Run tests")

  // The group in a finished step starts collapsed.
  const group = viewer.locator(".lv-group", {hasText: "Operating System"})
  await expect(group.locator(".lv-caret")).toHaveText("▸")
  await expect(viewer.locator(".lv-line", {hasText: "Ubuntu 24.04"})).toHaveCount(0)

  // First error, on a failed job.
  await page.locator(".lv-scroller").focus()
  await page.keyboard.press("e")
  await expect(viewer.locator(".lv-line.lv-error")).toContainText("Process completed with exit code 1.")
  await shot(page, layer, "job-github-log")

  // The VM's capture stays a click away.
  await page.locator("#show-live").click()
  await expect(page.locator("#log-source")).toContainText("Reported by the VM")
  await page.locator(".lv-scroller").focus()
  await page.keyboard.press("g")
  await expect(viewer.locator(".lv-line", {hasText: "hello from the null driver"})).toBeVisible()
  await expect(page.locator("#download-raw")).toHaveAttribute("href", /source=live$/)
  await page.locator("#show-github").click()
  await expect(page.locator("#download-raw")).toHaveAttribute("href", /source=github$/)
  await expect(viewer.locator(".lv-line", {hasText: "Current runner version"})).toBeVisible()

  // Steps scroll the log.
  await page.locator("#steps button", {hasText: "Set up job"}).click()
  await expect(viewer.locator(".lv-line[data-n='1']")).toBeVisible()

  // Download raw.
  const href = await page.locator("#download-raw").getAttribute("href")
  const resp = await page.request.get(href)
  expect(resp.status()).toBe(200)
  expect(resp.headers()["content-type"]).toBe("text/plain; charset=utf-8")
  expect(resp.headers()["x-content-type-options"]).toBe("nosniff")
  expect(resp.headers()["content-disposition"]).toContain("attachment")
  expect(await resp.text()).toContain("Process completed with exit code 1.")
})

test("the job page in the dark theme, and at 360 px", async ({page, request}) => {
  await signIn(page)
  const run = (await fakeState(request)).runs.find(r => r.name === "Logs")
  const job = (await fakeState(request)).jobs.find(j => j.run_id === run.id)
  await openJob(page, run, job)
  await page.evaluate(() => {
    localStorage.setItem("phx:theme", "dark")
    document.documentElement.setAttribute("data-theme", "dark")
  })
  await shot(page, layer, "job-dark")
  await page.setViewportSize({width: 360, height: 800})
  await openJob(page, run, job)
  await expect(page.locator("#log-viewer .lv-line").first()).toBeVisible()
  // The toolbar wraps rather than running off the screen.
  const bar = await page.locator(".lv-bar").evaluate(b => b.scrollWidth <= b.clientWidth + 1)
  expect(bar).toBe(true)
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)
  expect(overflow).toBe(false)
  await shot(page, layer, "job-mobile")
})
