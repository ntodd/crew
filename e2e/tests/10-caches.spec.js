// The Caches page (§17.3) in a real browser: each box's cache, the
// enabled hosts, the allowlist and Rotate CA, under production's style
// policy. (The allowlist's public check fetches from the real
// registries, so it's covered by the control plane's tests instead.)
import {expect, test} from "@playwright/test"
import {addBox, shot, signIn, startAgent, stopAgent} from "./helpers.js"

const layer = "10-cache"
let agent

test.describe.configure({mode: "serial"})
test.afterAll(() => stopAgent(agent))

test("box caches, hosts, the allowlist and the CA", async ({page}) => {
  test.setTimeout(240_000)
  const violations = []
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(m.text())
  })

  await signIn(page)
  const token = await addBox(page, "null-cache")
  agent = startAgent(token, {name: "null-cache"})
  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", {hasText: "null-cache"})).toContainText("Online", {timeout: 180_000})

  await page.goto("/admin/caches")
  await expect(page.locator("#box-caches")).toContainText("null-cache")
  await expect(page.locator("#allowlist")).toContainText("ghcr.io/actions/*")
  await shot(page, layer, "caches")

  // Turn quay.io off.
  await page.locator('#hosts input[type=checkbox][name="hosts[quay.io]"]').uncheck()
  await page.getByRole("button", {name: "Save hosts"}).click()
  await expect(page.locator("#flash-info, [role=alert]").first()).toContainText("Hosts saved")
  await page.reload()
  await expect(page.locator('#hosts input[type=checkbox][name="hosts[quay.io]"]')).not.toBeChecked()

  // Remove an entry.
  await page.locator('[data-entry="mcr.microsoft.com/*"] button').click()
  await expect(page.locator("#allowlist")).not.toContainText("mcr.microsoft.com/*")

  // Rotate the CA.
  const generation = await page.locator("#ca").innerText()
  page.once("dialog", d => d.accept())
  await page.locator("#rotate-ca").click()
  await expect(page.locator("#ca")).not.toHaveText(generation)

  await page.setViewportSize({width: 360, height: 800})
  await page.goto("/admin/caches")
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  await shot(page, layer, "caches-mobile")
  expect(violations).toEqual([])
})
