// Usage (§16.6): the usage page, the dashboard's counter, and the box
// and repo pages' panels, over two weeks of seeded VMs and jobs on three
// boxes (e2e/seeds/usage.exs).
// Runs only against a control plane started with that seed:
//
//   E2E_SEED=seeds/usage.exs npx playwright test tests/19-usage.spec.js
import {expect, test} from "@playwright/test"
import {connected, setTheme, shot, signIn} from "./helpers.js"

const layer = "19-usage"
const violations = []

test.describe.configure({mode: "serial"})
test.skip(process.env.E2E_SEED !== "seeds/usage.exs", "set E2E_SEED=seeds/usage.exs")
test.beforeEach(({page}) => {
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(`${page.url()}: ${m.text()}`)
  })
})
test.afterEach(() => expect(violations).toEqual([]))

// Whether every table on the page fits without scrolling sideways.
async function tablesFit(page) {
  return page.locator(".overflow-x-auto").evaluateAll(els => els.every(el => el.scrollWidth <= el.clientWidth))
}

test("the usage page: totals, the chart, and each breakdown", async ({page}) => {
  await signIn(page)
  await page.getByRole("link", {name: "Usage"}).click()
  await connected(page)

  await expect(page.getByText("Days are UTC")).toBeVisible()
  await expect(page.locator("#range-30")).toHaveAttribute("aria-current", "true")
  await expect(page.locator("#usage-job-minutes")).not.toHaveText("0")
  await expect(page.locator("#usage-totals")).toContainText("rounded up per job, as GitHub bills")
  await expect(page.locator("#usage-overhead")).toHaveText(/\d+%/)
  await expect(page.locator("#usage-chart path.chart-area").first()).toBeVisible()
  await expect(page.locator("#usage-chart path.chart-line")).toHaveCount(1)
  // Dates along the bottom, not times of day.
  await expect(page.locator("#usage-chart-ticks time").first()).toHaveText(/^[A-Z][a-z]{2} \d{1,2}$/)

  const boxes = page.locator("#usage-box-rows > tr")
  await expect(boxes).toHaveCount(3)
  await expect(page.locator("#usage-boxes")).toContainText("rack-1")
  await expect(page.locator("#usage-boxes")).toContainText("m3-mini")
  await expect(page.locator("#usage-repos")).toContainText("mona/storefront")
  await expect(page.locator("#usage-repos")).toContainText("mona/payments")
  await expect(page.locator("#usage-sizes")).toContainText("m (4 vCPU · 8.0 GiB)")
  await expect(page.locator("#usage-sizes")).toContainText("xs")

  await shot(page, layer, "page")
  await setTheme(page, "dark")
  await shot(page, layer, "page-dark")
  await setTheme(page, "light")

  // The tooltip names each day in UTC.
  await page.locator("#usage-chart-plot").hover()
  await expect(page.locator("#usage-chart [data-tooltip]")).toContainText("Busy")
  await expect(page.locator("#usage-chart [data-tooltip] p").first()).toHaveText(/^[A-Z][a-z]{2} \d{1,2}$/)

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  expect(await tablesFit(page)).toBe(true)
  await shot(page, layer, "page-mobile")
  await page.setViewportSize({width: 1440, height: 900})
})

test("the range is in the URL", async ({page}) => {
  await signIn(page)
  await page.goto("/usage")
  await connected(page)
  const thirty = await page.locator("#usage-job-minutes").textContent()

  await page.locator("#range-7").click()
  await expect(page).toHaveURL(/\/usage\?days=7$/)
  await expect(page.locator("#range-7")).toHaveAttribute("aria-current", "true")
  await expect(page.getByText("over the last 7 days")).toBeVisible()
  expect(await page.locator("#usage-job-minutes").textContent()).not.toEqual(thirty)

  await page.locator("#range-90").click()
  await expect(page).toHaveURL(/\/usage\?days=90$/)
  await expect(page.locator("#usage-job-minutes")).toHaveText(thirty)
})

test("the dashboard counts today's job minutes", async ({page}) => {
  await signIn(page)
  await page.goto("/")
  await connected(page)
  const counter = page.locator('#counters a[href="/usage"]')
  await expect(counter).toContainText("Job minutes today")
  await expect(counter).toContainText(/[\d,]+ yesterday, UTC/)
  await shot(page, layer, "dashboard", {fullPage: false})
  await counter.click()
  await expect(page).toHaveURL(/\/usage$/)
})

test("a box's page: its last 30 days", async ({page}) => {
  await signIn(page)
  await page.goto("/usage")
  await connected(page)
  await page.locator("#usage-boxes").getByRole("link", {name: "rack-1"}).click()
  await connected(page)

  const panel = page.locator("#usage")
  await expect(panel).toContainText("Last 30 days. Days are UTC.")
  await expect(page.locator("#usage-vm-minutes")).not.toHaveText("0")
  await expect(page.locator("#usage-mem-use")).toHaveText(/\d+%/)
  await expect(page.locator("#usage-chart path.chart-area").first()).toBeVisible()
  await expect(page.locator("#usage-repos li")).toHaveCount(3)
  await expect(panel.getByRole("link", {name: "All usage"})).toHaveAttribute("href", "/usage")
  await panel.scrollIntoViewIfNeeded()
  await shot(page, layer, "box", {fullPage: false})
  await setTheme(page, "dark")
  await shot(page, layer, "box-dark", {fullPage: false})
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  await page.locator("#usage").scrollIntoViewIfNeeded()
  await shot(page, layer, "box-mobile", {fullPage: false})
  await page.setViewportSize({width: 1440, height: 900})
})

test("a repo's page: its last 30 days and its top jobs", async ({page}) => {
  await signIn(page)
  await page.goto("/usage")
  await connected(page)
  await page.locator("#usage-repos").getByRole("link", {name: "mona/storefront"}).click()
  await connected(page)

  const panel = page.locator("#usage")
  await expect(page.locator("#usage-jobs")).not.toHaveText("0")
  await expect(panel).toContainText("rounded up")
  await expect(page.locator("#usage-overhead")).toHaveText(/\d+%/)
  await expect(page.locator("#usage-chart path.chart-area").first()).toBeVisible()
  await expect(page.locator("#usage-top-jobs li")).toHaveCount(4)
  await expect(page.locator("#usage-top-jobs")).toContainText("CI · e2e")
  await panel.scrollIntoViewIfNeeded()
  await shot(page, layer, "repo", {fullPage: false})
  await setTheme(page, "dark")
  await shot(page, layer, "repo-dark", {fullPage: false})
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  await page.locator("#usage").scrollIntoViewIfNeeded()
  await shot(page, layer, "repo-mobile", {fullPage: false})
  await page.setViewportSize({width: 1440, height: 900})
})
