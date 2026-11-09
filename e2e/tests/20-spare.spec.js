// Spare jobs (§7.2): the Queue page's tiers, a box at its spare share,
// and the dashboard's waiting counter, over e2e/seeds/spare.exs.
// Runs only against a control plane started with that seed:
//
//   E2E_SEED=seeds/spare.exs npx playwright test tests/20-spare.spec.js
import {expect, test} from "@playwright/test"
import {connected, fakePost, setTheme, shot, signIn} from "./helpers.js"

const layer = "20-spare"
const violations = []

test.describe.configure({mode: "serial"})
test.skip(process.env.E2E_SEED !== "seeds/spare.exs", "set E2E_SEED=seeds/spare.exs")
test.beforeEach(({page}) => {
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(`${page.url()}: ${m.text()}`)
  })
})
test.afterEach(() => expect(violations).toEqual([]))

// Setup's sync archives the seed's repos, which the fake GitHub doesn't
// list; adding them by their ids moves them to its installation.
async function start(page, request) {
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: [{name: "flakes", id: 990301}, {name: "storefront", id: 990302}]})
}

test("the queue tags spare jobs and their class", async ({page, request}) => {
  await start(page, request)
  await page.goto("/queue")
  await connected(page)
  await expect(page.locator("#units")).toContainText("mona/flakes")

  const units = page.locator("#units")
  const legs = units.locator("li", {hasText: "flake-hunt"})
  await expect(legs).toHaveCount(2)
  for (const leg of await legs.all()) await expect(leg.locator("[data-tier=spare]")).toHaveText("spare")

  const e2e = units.locator("li", {hasText: "e2e"})
  await expect(e2e).toContainText("crew-xl")
  await expect(e2e.locator("[data-tier]")).toHaveCount(0)

  const classes = page.locator("#classes")
  await expect(classes.locator("tr", {hasText: "crew-m-spare"}).locator("[data-tier=spare]")).toBeVisible()
  await expect(classes.locator("tr", {hasText: "crew-xl"}).locator("[data-tier]")).toHaveCount(0)

  await shot(page, layer, "queue", {fullPage: false})
  await setTheme(page, "dark")
  await shot(page, layer, "queue-dark", {fullPage: false})
  await setTheme(page, "light")
})

test("a box at its spare share", async ({page, request}) => {
  await start(page, request)
  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: "rack-1"}).click()
  await connected(page)

  // 23 × 1.5 = 34.5 vCPUs and 60,212 MiB; half of each for spare VMs.
  await expect(page.locator("#capacity-all")).toHaveText(/4 VMs · 20 of 34 vCPUs · 41\.2 of 58\.8 GiB/)
  await expect(page.locator("#capacity-spare")).toHaveText(/3 VMs · 12 of 17 vCPUs · 24\.8 of 29\.4 GiB\s*\(50% share\)/)
  await expect(page.locator("#vms [data-tier=spare]")).toHaveCount(3)
  await expect(page.locator("#box_spare_pct")).toHaveValue("50")

  await page.locator("#capacity").scrollIntoViewIfNeeded()
  await shot(page, layer, "box-capacity", {fullPage: false})
  await setTheme(page, "dark")
  await shot(page, layer, "box-capacity-dark", {fullPage: false})
  await setTheme(page, "light")

  await page.locator("#vms").scrollIntoViewIfNeeded()
  await shot(page, layer, "box-vms", {fullPage: false})
})

test("the dashboard counts regular jobs waiting, and notes the spare ones", async ({page, request}) => {
  await page.setViewportSize({width: 390, height: 844})
  await start(page, request)
  await page.goto("/")
  await connected(page)

  const waiting = page.locator('#counters a[href="/runs?status=queued"]')
  await expect(waiting.locator("p.text-2xl")).toHaveText("1")
  await expect(page.locator("#waiting-spare")).toHaveText("+ 2 spare")
  await expect(page.locator('#counters a[href="/runs?status=in_progress"] p.text-2xl')).toHaveText("4")

  await page.locator("#counters").scrollIntoViewIfNeeded()
  await shot(page, layer, "dashboard-mobile", {fullPage: false})
  await setTheme(page, "dark")
  await shot(page, layer, "dashboard-mobile-dark", {fullPage: false})
  await setTheme(page, "light")
  await page.setViewportSize({width: 1440, height: 900})
})

test("a waiting spare job's page tags it next to its size", async ({page, request}) => {
  await start(page, request)
  await page.goto("/runs/9700001/attempts/1/jobs/9600005")
  await connected(page)

  await expect(page.locator("#placement")).toContainText("m")
  await expect(page.locator("#placement [data-tier=spare]")).toHaveText("spare")
  await shot(page, layer, "job", {fullPage: false})
})
