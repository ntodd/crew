// GitHub intake end to end: repos arrive with installation_repositories,
// runs and jobs with signed webhooks, and the Runs page shows Crew's
// view of each job, live. Runs after 01-setup, on the same deployment.
import { expect, test } from "@playwright/test"
import { fakePost, fakeState, shot, signIn } from "./helpers.js"

const layer = "03-github-intake"

test.describe.configure({ mode: "serial" })

test("repos, runs and jobs come in over webhooks", async ({ page, request }) => {
  await signIn(page)
  await fakePost(request, "/__fake/repos", { names: ["app", "site"] })

  await page.goto("/repos")
  await expect(page.getByRole("link", { name: "mona/app" })).toBeVisible()
  await expect(page.getByRole("link", { name: "mona/site" })).toBeVisible()
  await shot(page, layer, "repos")

  await page.goto("/runs")
  await expect(page.locator("#runs-empty")).toBeVisible()

  const { run, jobs } = await fakePost(request, "/__fake/runs", {
    repo: "mona/app",
    workflow: "CI",
    message: "Make the tests faster",
    jobs: [
      { name: "test", labels: ["crew-m"] },
      { name: "build", labels: ["crew-l-arm64"] },
      { name: "huge", labels: ["crew-huge"] },
      { name: "lint", labels: ["ubuntu-latest"] },
    ],
  })

  // Live: no reload.
  const row = page.locator(`#run-${run.id}`)
  await expect(row).toBeVisible()
  await expect(row).toContainText("CI")
  // Jobs arrive over separate webhooks, processed by Oban: give a busy
  // machine time.
  await expect(row.locator("[data-job-state]")).toHaveCount(4, {timeout: 30_000})
  await shot(page, layer, "runs")

  await row.getByRole("link", { name: /CI/ }).click()
  await expect(page.locator("#commit-message")).toHaveText("Make the tests faster")
  // Waiting, or Blocked (no boxes enrolled) once the scheduler has had a pass.
  await expect(page.locator(`#job-${jobs[0].id}`)).toContainText(/Waiting|Blocked/)
  await expect(page.locator(`#job-${jobs[1].id}`)).toContainText("crew-l-arm64")
  await expect(page.locator(`#job-${jobs[2].id}`)).toContainText("Can't run")
  await expect(page.locator(`#job-${jobs[2].id}`)).toContainText("unknown size huge")
  await expect(page.locator(`#job-${jobs[3].id}`)).toContainText("Not a Crew job")
  await shot(page, layer, "run")

  // A GitHub-hosted job runs and finishes: the page follows.
  await fakePost(request, `/__fake/jobs/${jobs[3].id}`, { status: "in_progress", runner_name: "GitHub Actions 7" })
  await expect(page.locator(`#job-${jobs[3].id}`)).toContainText("ran on GitHub Actions 7")
  await fakePost(request, `/__fake/jobs/${jobs[3].id}`, { status: "completed", conclusion: "success" })
  await expect(page.locator(`#job-${jobs[3].id} [data-job-state=not_ours]`)).toBeVisible()
})

test("a fork PR is refused, and its run cancelled", async ({ page, request }) => {
  await signIn(page)
  const { run, jobs } = await fakePost(request, "/__fake/runs", {
    repo: "mona/app",
    workflow: "PR checks",
    event: "pull_request",
    head_repo: "stranger/app",
    branch: "patch-1",
    pr: 12,
    jobs: [{ name: "test", labels: ["crew-m"] }],
  })

  await page.goto(`/runs/${run.id}/attempts/1`)
  await expect(page.locator(`#job-${jobs[0].id}`)).toContainText("Refused")
  await expect(page.locator(`#job-${jobs[0].id}`)).toContainText("fork PRs are refused on this repo")
  await shot(page, layer, "fork-refused")

  await expect.poll(async () => (await fakeState(request)).cancelled).toContain(run.id)

  await page.goto("/runs?pr=12")
  await expect(page.locator(`#run-${run.id}`)).toContainText("PR #12")
})

test("repo settings re-parse queued jobs", async ({ page, request }) => {
  await signIn(page)
  const { run, jobs } = await fakePost(request, "/__fake/runs", {
    repo: "mona/site",
    jobs: [{ name: "big", labels: ["crew-xl"] }],
  })

  await page.goto("/repos")
  await page.getByRole("link", { name: "mona/site" }).click()
  await expect(page.locator("#snippets")).toContainText("runs-on: crew-xl")
  await page.getByRole("checkbox", { name: "s", exact: true }).check()
  await page.getByRole("checkbox", { name: "m", exact: true }).check()
  await page.getByRole("button", { name: "Save" }).click()
  await expect(page.getByText("Saved.")).toBeVisible()
  await expect(page.locator("#snippets")).not.toContainText("runs-on: crew-xl")
  await shot(page, layer, "repo-settings")

  await page.goto(`/runs/${run.id}/attempts/1`)
  await expect(page.locator(`#job-${jobs[0].id}`)).toContainText("size xl not allowed for this repo")
})

test("the Deployment page shows webhook health", async ({ page, request }) => {
  await signIn(page)
  await fakePost(request, "/__fake/ping")
  await page.goto("/admin")
  await expect(page.locator("#last-ping")).not.toHaveText("never")
  await expect(page.locator("#last-delivery")).not.toHaveText("never")
  await shot(page, layer, "deployment")
})

test("the Runs page is usable at 360 px", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 })
  await signIn(page)
  await page.goto("/runs")
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  expect(overflow).toBeLessThanOrEqual(0)
  await shot(page, layer, "runs-narrow")
})
