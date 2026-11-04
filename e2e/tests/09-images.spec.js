// Guest images (§13.1, §20.4) in a real browser: the control plane
// registers the release it carries (crew-server.sh makes a small one,
// signed with the development key), fetches its files, and a box
// prepares the default; the Images page shows the rollout, and pinning
// and unpinning roll back and forward.
import {expect, test} from "@playwright/test"
import {addBox, connected, shot, signIn, startAgent, stopAgent} from "./helpers.js"

const layer = "09-guest-image"
let agent

test.describe.configure({mode: "serial"})
test.afterAll(() => stopAgent(agent))

test("the release's image is registered, fetched and prepared on a box", async ({page}) => {
  test.setTimeout(240_000)
  await signIn(page)
  await page.goto("/admin/images")
  const arm = page.locator("#arch-arm64")
  await expect(arm.locator("#default-arm64")).toContainText("2.338.2", {timeout: 30_000})
  await expect(arm.locator("#default-arm64")).toContainText("29.9.2")
  await expect(arm.locator("[id^=image-]").first()).toContainText("default")
  // actions/runner has moved on (the fake's releases): the page warns.
  await expect(page.locator("#runner-freshness")).toContainText("16 days behind actions/runner 2.339.0")

  const token = await addBox(page, "null-img")
  agent = startAgent(token, {name: "null-img"})
  await page.goto("/boxes")
  await expect(page.locator("[id^=box-]", {hasText: "null-img"})).toContainText("Online", {timeout: 180_000})

  await page.goto("/admin/images")
  await expect(page.locator("#rollout-arm64")).toContainText("null-img")
  await expect(page.locator("#rollout-arm64")).toContainText("ready", {timeout: 30_000})
  await shot(page, layer, "images")
})

test("pinning and unpinning", async ({page}) => {
  await signIn(page)
  await page.goto("/admin/images")
  await connected(page)
  const pin = page.locator("#arch-arm64 [id^=pin-]").first()
  page.once("dialog", d => d.accept())
  await pin.click()
  await expect(page.locator("#default-arm64")).toContainText("pinned")
  await page.locator("#arch-arm64 [id^=unpin-]").first().click()
  await expect(page.locator("#default-arm64")).not.toContainText("pinned")

  await page.setViewportSize({width: 360, height: 800})
  await page.goto("/admin/images")
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  await shot(page, layer, "images-mobile")
})
