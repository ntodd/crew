// The repo list's filters (§17.3): the search and the toggles, kept in
// the URL, and the empty state for nothing matching. Earlier files' repos
// may be on the list too, so this checks its own repos, not counts.
import {expect, test} from "@playwright/test"
import {connected, fakePost, setTheme, shot, signIn} from "./helpers.js"

const layer = "17-repos"
const violations = []

test.describe.configure({mode: "serial"})
test.beforeEach(({page}) => {
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(`${page.url()}: ${m.text()}`)
  })
})
test.afterEach(() => expect(violations).toEqual([]))

const row = (page, name) => page.locator("#repos-panel li", {has: page.getByRole("link", {name: `mona/${name}`, exact: true})})

async function settings(page, name, {enabled = true, priority = 0}) {
  await page.goto("/repos")
  await page.getByRole("link", {name: `mona/${name}`, exact: true}).click()
  await connected(page)
  await page.getByLabel("Run this repo's Crew jobs").setChecked(enabled)
  await page.getByLabel("Priority (higher is placed first)").fill(String(priority))
  await page.getByRole("button", {name: "Save"}).click()
  await expect(page.getByText("Saved.")).toBeVisible()
}

test("filtering the repo list", async ({page, request}) => {
  await signIn(page)
  await fakePost(request, "/__fake/repos", {names: ["storefront", "storefront-api", "billing-legacy", "payments", "nightly-reports"]})
  await fakePost(request, "/__fake/repos", {names: ["docs", "design-system"], private: false})
  // Crew takes the webhook in a background job and the list loads once,
  // so reload until every repo is in.
  const seeded = ["storefront", "storefront-api", "billing-legacy", "payments", "nightly-reports", "docs", "design-system"]
  await expect(async () => {
    await page.goto("/repos")
    for (const name of seeded) await expect(row(page, name)).toBeVisible({timeout: 500})
  }).toPass({timeout: 30_000})

  await settings(page, "billing-legacy", {enabled: false})
  await settings(page, "payments", {priority: 5})
  await settings(page, "nightly-reports", {priority: -1})

  await page.goto("/repos")
  await connected(page)
  await shot(page, layer, "repos")

  // Typing narrows the list and lands in the URL, trimmed, without the
  // box losing what was typed; the URL survives a reload.
  const search = page.getByRole("searchbox", {name: "Search repos by name"})
  await search.fill(" STOREfront ")
  await expect(page).toHaveURL(/\/repos\?q=STOREfront$/)
  await expect(search).toHaveValue(" STOREfront ")
  await expect(row(page, "storefront")).toBeVisible()
  await expect(row(page, "storefront-api")).toBeVisible()
  await expect(row(page, "payments")).toHaveCount(0)
  await expect(page.locator("#repo-count")).toHaveText(/\b2 of \d+ repos\b/)
  await page.reload()
  await connected(page)
  await expect(search).toHaveValue("STOREfront")
  await expect(row(page, "payments")).toHaveCount(0)
  await expect(row(page, "storefront-api")).toBeVisible()
  await search.fill("")
  await expect(page).toHaveURL(/\/repos$/)

  // Each toggle, on its own.
  await page.getByLabel("State", {exact: true}).selectOption("disabled")
  await expect(page).toHaveURL(/state=disabled/)
  await expect(row(page, "billing-legacy")).toBeVisible()
  await expect(row(page, "storefront")).toHaveCount(0)
  // Back undoes a filter, as the URL changed with it.
  await page.goBack()
  await expect(page).toHaveURL(/\/repos$/)
  await expect(page.getByLabel("State", {exact: true})).toHaveValue("")
  await expect(row(page, "storefront")).toBeVisible()

  await page.getByLabel("Visibility", {exact: true}).selectOption("public")
  await expect(page).toHaveURL(/visibility=public/)
  await expect(row(page, "docs")).toBeVisible()
  await expect(row(page, "design-system")).toBeVisible()
  await expect(row(page, "storefront")).toHaveCount(0)
  await page.getByLabel("Visibility", {exact: true}).selectOption("")

  await page.getByLabel("Has a priority").check()
  await expect(page).toHaveURL(/priority=true/)
  await expect(row(page, "payments")).toContainText("Priority 5")
  await expect(row(page, "nightly-reports")).toContainText("Priority -1")
  await expect(row(page, "storefront")).toHaveCount(0)
  await shot(page, layer, "repos-priority")
  await setTheme(page, "dark")
  await shot(page, layer, "repos-priority-dark")
  await setTheme(page, "light")
  await page.getByLabel("Has a priority").uncheck()
  await expect(page).toHaveURL(/\/repos$/)
  await expect(row(page, "storefront")).toBeVisible()
  await page.getByLabel("Has a priority").check()
  await expect(page).toHaveURL(/priority=true/)

  // Nothing matching says so, apart from "install the App", with a way out.
  await search.fill("storefront")
  await expect(page.locator("#repos-no-match")).toContainText("No repos match these filters.")
  await expect(page.locator("#repos-empty")).toHaveCount(0)
  await shot(page, layer, "repos-no-match")
  await page.getByRole("link", {name: "Clear filters"}).click()
  await expect(page).toHaveURL(/\/repos$/)
  await expect(search).toHaveValue("")
  await expect(page.getByLabel("Has a priority")).not.toBeChecked()
  await expect(row(page, "storefront")).toBeVisible()

  // On a phone the toolbar stacks, and nothing runs off the side.
  await page.setViewportSize({width: 390, height: 844})
  await page.goto("/repos?visibility=private&q=s")
  await connected(page)
  await expect(row(page, "storefront")).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
  await shot(page, layer, "repos-mobile")
  await setTheme(page, "dark")
  await shot(page, layer, "repos-mobile-dark")
  await setTheme(page, "light")
})
