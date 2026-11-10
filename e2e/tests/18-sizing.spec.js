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
  // Each hint with a size to move to can become an issue; a custom one
  // can't until the size exists.
  await expect(rows.nth(0).getByRole("link", {name: "File issue"})).toHaveCount(0)
  await expect(rows.nth(1).getByRole("link", {name: "File issue"})).toHaveAttribute("href", /^https:\/\/github\.com\/mona\/storefront\/issues\/new\?/)
  await expect(rows.nth(1).getByRole("button", {name: "Copy as Markdown"})).toBeVisible()

  // Or one issue for them all, by workflow file.
  const all = new URL(await page.locator("#sizing-repo-issue").getByRole("link", {name: "File one issue"}).getAttribute("href"))
  expect(all.searchParams.get("title")).toBe("Right-size 3 jobs in mona/storefront")
  const checklist = all.searchParams.get("body")
  expect(checklist).toContain("### [`.github/workflows/ci.yml`](https://github.com/mona/storefront/blob/main/.github/workflows/ci.yml)")
  expect(checklist).toContain("- [ ] **CI · test**: `crew-m` → `crew-xs`.")
  expect(checklist).toContain("- [ ] **CI · e2e**: `crew-l` → `crew-xl`.")
  expect(checklist).toContain("### [`.github/workflows/nightly.yml`]")
  expect(checklist).not.toContain("CI · build")
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
  // The run's workflow file, where that line goes.
  const file = panel.getByRole("link", {name: ".github/workflows/ci.yml"})
  await expect(file).toHaveAttribute("href", "https://github.com/mona/storefront/blob/main/.github/workflows/ci.yml")
  await expect(file).toHaveAttribute("target", "_blank")

  // An issue for the move: GitHub's form, filled in.
  const issue = panel.getByRole("link", {name: "File issue"})
  await expect(issue).toHaveAttribute("target", "_blank")
  const url = new URL(await issue.getAttribute("href"))
  expect(url.origin + url.pathname).toBe("https://github.com/mona/storefront/issues/new")
  expect(url.searchParams.get("title")).toBe("Move CI · test to crew-xs")
  const body = url.searchParams.get("body")
  expect(body).toContain("```diff\n- runs-on: crew-m\n+ runs-on: crew-xs\n```")
  expect(body).toContain("In [`.github/workflows/ci.yml`](https://github.com/mona/storefront/blob/main/.github/workflows/ci.yml).")
  expect(body).toContain("- Memory peaked at")

  // Or the same as Markdown, for a tracker that isn't GitHub.
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"])
  // By id: the button's name changes while it says Copied.
  const copy = page.locator("#sizing-issue-copy")
  await expect(copy).toHaveText("Copy as Markdown")
  await copy.click()
  await expect(copy).toContainText("Copied")
  const copied = await page.evaluate(() => navigator.clipboard.readText())
  expect(copied).toBe(`# Move CI · test to crew-xs\n\n${body}`)
  await expect(copy).toContainText("Copy as Markdown")
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
  await expect(panel.getByRole("link", {name: "Sizes & labels"})).toHaveAttribute("href", /^\/admin\/sizes\?vcpus=4&memory_mib=2048&disk_gib=20&repos\[\]=/)
  await expect(panel.getByRole("link", {name: "File issue"})).toHaveCount(0)
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
  await expect(page.locator("#sizing-hints").getByRole("link", {name: "File issue"})).toHaveCount(3)
  await expect(page.locator("#sizing-repo-rows")).toContainText("mona/storefront")
  // One issue per repo, from its row, with what its changes do in a week.
  const repoIssue = new URL(await page.locator("#sizing-repo-rows").getByRole("link", {name: "File issue"}).getAttribute("href"))
  expect(repoIssue.searchParams.get("title")).toMatch(/^Right-size 3 jobs in mona\/storefront: takes [0-9.]+ GiB-hours a week$/)
  expect(repoIssue.searchParams.get("body")).toMatch(/Over the last 7 days, the changes would have freed [0-9.]+ GiB-hours of reserved memory and taken [0-9.]+\./)
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

test("an admin dismisses a hint, with why, and restores it", async ({page}) => {
  await signIn(page)
  await page.goto("/sizing")
  await connected(page)

  const row = page.locator("#sizing-hints > li", {hasText: "Nightly · integration"})
  const needsMore = await page.locator("#sizing-needs-more").textContent()
  await row.getByRole("button", {name: "Dismiss"}).click()
  const reason = row.getByRole("textbox", {name: "Why dismiss it (optional)"})
  await expect(reason).toBeFocused()
  await reason.fill("integration is slow on purpose")
  await shot(page, layer, "dismiss-form")
  await row.getByRole("button", {name: "Dismiss"}).click()

  await expect(page.locator("#sizing-hints > li")).toHaveCount(3)
  await expect(page.locator("#sizing-hints")).not.toContainText("Nightly · integration")
  await expect(page.locator("#sizing-needs-more")).toHaveText(needsMore)
  await page.locator("#sizing-dismissed-toggle").click()
  const dismissed = page.locator("#sizing-dismissed > li")
  await expect(dismissed).toHaveCount(1)
  await expect(dismissed).toContainText("Nightly · integration")
  await expect(dismissed).toContainText("mona/storefront")
  await expect(dismissed).toContainText(/Dismissed by mona on \w+ \d+: integration is slow on purpose/)
  expect(await rowOverflows(page)).toEqual([])
  await shot(page, layer, "dismissed")
  await setTheme(page, "dark")
  await shot(page, layer, "dismissed-dark")
  await setTheme(page, "light")
  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  await page.locator("#sizing-dismissed-toggle").click()
  await expect(page.locator("#sizing-dismissed > li")).toHaveCount(1)
  expect(await rowOverflows(page)).toEqual([])
  await shot(page, layer, "dismissed-mobile")
  await page.setViewportSize({width: 1440, height: 900})

  // The repo page lists it apart too, and its issue leaves it out.
  await openRepo(page)
  const all = new URL(await page.locator("#sizing-repo-issue").getByRole("link", {name: "File one issue"}).getAttribute("href"))
  expect(all.searchParams.get("title")).toBe("Right-size 2 jobs in mona/storefront")
  await page.locator("#sizing-dismissed-toggle").click()
  await expect(page.locator("#sizing-dismissed > li")).toContainText("integration is slow on purpose")
  await shot(page, layer, "repo-dismissed")

  // Its job page says so, with no issue to file.
  await page.locator("#sizing-dismissed").getByRole("link", {name: "Nightly · integration"}).click()
  await connected(page)
  await expect(page.locator("#sizing-dismissed")).toContainText("integration is slow on purpose")
  await expect(page.locator("#sizing").getByRole("link", {name: "File issue"})).toHaveCount(0)
  await shot(page, layer, "job-dismissed")

  await page.locator("#sizing-dismissed").getByRole("button", {name: "Restore"}).click()
  await expect(page.locator("#sizing-dismissed")).toHaveCount(0)
  await expect(page.locator("#sizing").getByRole("link", {name: "File issue"})).toBeVisible()

  await page.goto("/sizing")
  await connected(page)
  await expect(page.locator("#sizing-hints > li")).toHaveCount(4)
  await expect(page.locator("#sizing-dismissed-toggle")).toHaveCount(0)
})

test("more vCPUs for a starved job on its runs' critical path, and why not for one off it", async ({page}) => {
  await signIn(page)
  await openRepo(page)
  await page.getByRole("link", {name: "Nightly · integration"}).click()
  await connected(page)

  let panel = page.locator("#sizing")
  await expect(panel).toContainText("Could run faster on m")
  await expect(panel).toContainText("It was on its run's critical path in 6 of the 6 runs where it waited")
  await shot(page, layer, "job-faster")

  // Release · docs: e2e/seeds/sizing.exs's last runs.
  await page.goto("/runs/7790001/attempts/1/jobs/8890001")
  await connected(page)
  panel = page.locator("#sizing")
  await expect(panel).toContainText("m fits")
  await expect(panel).toContainText("off its run's critical path in 5 of the 5 runs where it waited")
  await expect(panel).not.toContainText("Could run faster")
  await shot(page, layer, "job-off-path")
  await setTheme(page, "dark")
  await shot(page, layer, "job-off-path-dark")
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  await shot(page, layer, "job-off-path-mobile")
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

// CI · lint moved from l to m in e2e/seeds/sizing.exs, and its runs on m
// take 9 minutes against 8m 20s on l.
test("the right-sizing page shows which changes worked", async ({page}) => {
  await signIn(page)
  await page.goto("/sizing")
  await connected(page)

  const changes = page.locator("#sizing-changes > div > ul > li")
  await expect(changes).toHaveCount(1)
  const lint = changes.first()
  await expect(lint).toContainText("CI · lint")
  await expect(lint).toContainText("mona/storefront")
  await expect(lint).toContainText("l (8 vCPU · 16.0 GiB) → m (4 vCPU · 8.0 GiB)")
  await expect(lint).toContainText("8% slower")
  await expect(lint).toContainText("Median 8m 20s on l, 9m 00s on m")
  await expect(lint).toContainText("3 runs before, 6 since")
  await expect(lint).toContainText(/frees [0-9.]+ GiB-hours a week/)
  await shot(page, layer, "fleet-changes")
  await setTheme(page, "dark")
  await shot(page, layer, "fleet-changes-dark")
  await setTheme(page, "light")

  await page.setViewportSize({width: 390, height: 844})
  await page.reload()
  await connected(page)
  expect(await page.locator("#sizing-changes").evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
  await shot(page, layer, "fleet-changes-mobile")
  await page.setViewportSize({width: 1440, height: 900})

  await lint.getByRole("link", {name: "CI · lint"}).click()
  await connected(page)
  await expect(page.locator("#sizing-durations li")).toHaveCount(2)
})

// Last: it adds a size, which changes the hints the tests above expect.
test("a custom shape becomes a size an admin adds, and then a hint with an issue", async ({page}) => {
  await signIn(page)
  await page.goto("/sizing")
  await connected(page)

  // The shapes custom hints would fit, with the jobs each would serve.
  const shape = page.locator("#sizing-custom-4-2048-20")
  await expect(shape).toContainText("4 vCPU · 2.0 GiB · 20 GiB disk")
  await expect(shape).toContainText("1 job")
  await expect(shape).toContainText("CI · build")
  await expect(shape).toContainText("mona/storefront")
  await shot(page, layer, "fleet-custom")

  // The repo limits its sizes, so the new one has to be allowed there too.
  await openRepo(page)
  const settings = page.locator("#repo-settings")
  for (const name of ["xs", "s", "m", "l", "xl"]) await settings.getByLabel(name, {exact: true}).check()
  await settings.getByRole("button", {name: "Save"}).click()
  await expect(page.locator("#sizing-hints > li").first()).toContainText("A custom size would fit")

  await page.locator("#sizing-hints > li", {hasText: "CI · build"}).getByRole("link", {name: "Add this size"}).click()
  await page.waitForURL(/\/admin\/sizes\?/)
  await connected(page)
  const form = page.locator("#new-size")
  await expect(form.getByLabel("vCPUs")).toHaveValue("4")
  await expect(form.getByLabel("Memory (MiB)")).toHaveValue("2048")
  await expect(form.getByLabel("Disk (GiB)")).toHaveValue("20")
  const allow = page.locator("#new-size-allow")
  await expect(allow.getByLabel("mona/storefront")).toBeChecked()
  await form.getByLabel("Name").fill("c4")
  await shot(page, layer, "sizes-prefilled")
  await form.getByRole("button", {name: "Add size"}).click()
  await expect(page.getByText("Added c4. mona/storefront may use it.")).toBeVisible()
  await expect(page.locator("#new-size-allow")).toHaveCount(0)

  // The hint is now a size to move to, with its issue.
  await openRepo(page)
  const build = page.locator("#sizing-hints > li", {hasText: "CI · build"})
  await expect(build).toContainText("Try c4")
  const issue = new URL(await build.getByRole("link", {name: "File issue"}).getAttribute("href"))
  expect(issue.searchParams.get("title")).toBe("Move CI · build to crew-c4")
  await shot(page, layer, "repo-after-custom")
})
