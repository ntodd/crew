// Right-sizing hints (§7.5) on the repo page and the job page, for jobs
// whose finished runs have resource summaries (e2e/seeds/sizing.exs).
// Runs only against a control plane started with that seed:
//
//   E2E_SEED=seeds/sizing.exs npx playwright test tests/18-sizing.spec.js
import {expect, test} from "@playwright/test"
import {connected, fakePost, setTheme, shot, signIn} from "./helpers.js"

const layer = "18-sizing"
const violations = []

test.describe.configure({mode: "serial"})
test.skip(process.env.E2E_SEED !== "seeds/sizing.exs", "set E2E_SEED=seeds/sizing.exs")
test.beforeEach(({page}) => {
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(`${page.url()}: ${m.text()}`)
  })
})
test.afterEach(() => expect(violations).toEqual([]))

// Text that spills out of its hint row, or past the panel's edge.
async function rowOverflows(page) {
  return page.locator("#sizing-hints > li").evaluateAll(lis => {
    const out = []
    for (const li of lis) {
      const edge = li.getBoundingClientRect().right
      for (const el of li.querySelectorAll("*")) {
        const r = el.getBoundingClientRect()
        if (r.width > 0 && r.right > edge + 1) out.push(`${li.id}: "${el.textContent.trim().slice(0, 60)}" ends ${Math.round(r.right - edge)}px past its row`)
      }
    }
    return [...new Set(out)]
  })
}

async function openRepo(page) {
  await page.goto("/repos")
  await page.getByRole("link", {name: "mona/storefront", exact: true}).click()
  await connected(page)
}

// Setup syncs the App's installations and archives the repos of any it
// doesn't list, the seed's among them: installing the repo again, by its
// id, brings it back with its jobs.
test("the repo page lists its jobs' hints, the most memory freed first", async ({page, request}) => {
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: [{name: "storefront", id: 990101}]})
  await expect(async () => {
    await page.goto("/repos")
    await expect(page.getByRole("link", {name: "mona/storefront", exact: true})).toBeVisible({timeout: 500})
  }).toPass({timeout: 30_000})
  await openRepo(page)

  const rows = page.locator("#sizing-hints > li")
  await expect(rows).toHaveCount(4)
  await expect(rows.nth(0)).toContainText("CI · build")
  await expect(rows.nth(0)).toContainText("A custom size would fit")
  await expect(rows.nth(0)).toContainText("It needs 4 vCPUs and 2 GiB, but the closest allowed size, m, reserves 8 GiB.")
  await expect(rows.nth(1)).toContainText("CI · test")
  await expect(rows.nth(1)).toContainText("Try xs")
  await expect(page.locator("#sizing")).toContainText("Could run faster on m")
  await expect(page.locator("#sizing")).toContainText("Needs more memory: xl")
  await expect(page.locator("#sizing")).not.toContainText("lint")
  expect(await rowOverflows(page)).toEqual([])

  await shot(page, layer, "repo")
  await setTheme(page, "dark")
  await shot(page, layer, "repo-dark")
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  expect(await rowOverflows(page)).toEqual([])
  await shot(page, layer, "repo-mobile")
  await page.setViewportSize({width: 1440, height: 900})
})

test("a job's page shows its hint, with the runs-on line to use", async ({page}) => {
  await signIn(page)
  await openRepo(page)
  await page.getByRole("link", {name: "CI · test"}).click()
  await connected(page)

  const panel = page.locator("#sizing")
  await expect(panel).toContainText("From the last 8 runs of this job.")
  await expect(panel).toContainText("Try xs")
  await expect(panel).toContainText("frees 6.0 GiB a run")
  await expect(panel.locator("code")).toHaveText("runs-on: crew-xs")
  await shot(page, layer, "job-smaller")
  await setTheme(page, "dark")
  await shot(page, layer, "job-smaller-dark")
  await setTheme(page, "light")
})

test("a custom shape names what to add, and where", async ({page}) => {
  await signIn(page)
  await openRepo(page)
  await page.getByRole("link", {name: "CI · build"}).click()
  await connected(page)

  const panel = page.locator("#sizing")
  await expect(panel).toContainText("A custom size would fit")
  await expect(panel).toContainText("4 vCPU · 2.0 GiB · 20 GiB disk")
  await expect(panel.getByRole("link", {name: "Sizes & labels"})).toHaveAttribute("href", "/admin/sizes")
  await shot(page, layer, "job-custom")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  await shot(page, layer, "job-custom-mobile")
  await page.setViewportSize({width: 1440, height: 900})
})

test("a run killed for memory asks for more", async ({page}) => {
  await signIn(page)
  await openRepo(page)
  await page.getByRole("link", {name: "CI · e2e"}).click()
  await connected(page)

  const panel = page.locator("#sizing")
  await expect(panel).toContainText("Needs more memory: xl")
  await expect(panel).toContainText("1 of the last 6 runs had a process killed for memory.")
  await expect(panel.locator("code")).toHaveText("runs-on: crew-xl")
  await shot(page, layer, "job-larger")
})

test("the right-sizing page: the week's memory, each repo's share, every hint", async ({page}) => {
  await signIn(page)
  await page.getByRole("link", {name: "Right-sizing"}).click()
  await connected(page)

  await expect(page.locator("#sizing-reserved")).not.toHaveText("0.0")
  await expect(page.locator("#sizing-totals")).toContainText(/frees [0-9.]+, takes [0-9.]+ GiB-hours/)
  await expect(page.locator("#sizing-needs-more")).toHaveText("1")
  const hints = page.locator("#sizing-hints > li")
  await expect(hints).toHaveCount(4)
  await expect(hints.nth(0)).toContainText("mona/storefront")
  await expect(page.locator("#sizing-repo-rows")).toContainText("mona/storefront")
  expect(await rowOverflows(page)).toEqual([])
  await shot(page, layer, "fleet")
  await setTheme(page, "dark")
  await shot(page, layer, "fleet-dark")
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  expect(await rowOverflows(page)).toEqual([])
  // The by-repo table fits without scrolling sideways.
  const table = page.locator("#sizing-repos .overflow-x-auto")
  expect(await table.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
  await shot(page, layer, "fleet-mobile")
  await page.setViewportSize({width: 1440, height: 900})
})

// e2e/seeds/sizing.exs makes 26 runs before CI · lint's, the newest of
// which is its 27th.
test("a job that moved sizes shows its time on each", async ({page}) => {
  await signIn(page)
  await page.goto("/runs/7700027/attempts/1/jobs/8800027")
  await connected(page)

  const panel = page.locator("#sizing")
  await expect(panel).toContainText("m fits")
  const rows = page.locator("#sizing-durations li")
  await expect(rows).toHaveCount(2)
  await expect(rows.nth(0)).toContainText("m (4 vCPU · 8.0 GiB)")
  await expect(rows.nth(0)).toContainText("9m 00s")
  await expect(rows.nth(0)).toContainText("6 runs")
  await expect(rows.nth(1)).toContainText("l (8 vCPU · 16.0 GiB)")
  await expect(rows.nth(1)).toContainText("8m 20s")
  await shot(page, layer, "job-durations")
})
