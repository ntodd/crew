// Reboots (§12.1) and a mac-vz box's cache VM (§15.6) on the box page,
// for boxes as their agents reported them (e2e/seeds/reboots.exs). Runs
// only against a control plane started with that seed:
//
//   E2E_SEED=seeds/reboots.exs npx playwright test tests/16-reboots.spec.js
import {expect, test} from "@playwright/test"
import {setTheme, shot, signIn} from "./helpers.js"

const layer = "16-cache-vm"

test.describe.configure({mode: "serial"})
test.skip(process.env.E2E_SEED !== "seeds/reboots.exs", "set E2E_SEED=seeds/reboots.exs")

async function openBox(page, name) {
  await page.goto("/boxes")
  await page.locator("[id^=box-]", {hasText: name}).click()
}

test("a Flatcar box's pending update, then Reboot", async ({page}) => {
  await signIn(page)
  await openBox(page, "rack1")
  const panel = page.locator("#reboot")
  await expect(panel).toContainText("flatcar-4800.0.0")
  await expect(panel.locator('a[href="https://www.flatcar.org/releases#release-4800.0.0"]')).toBeVisible()
  await expect(page.locator("#reboot-box-now")).toHaveAttribute("data-confirm", /0 running jobs fail/)
  await shot(page, layer, "reboot-pending")

  page.once("dialog", d => d.accept())
  await page.locator("#reboot-box").click()
  await expect(panel).toContainText("Rebooting")
  await expect(page.locator("#reboot-box")).toHaveCount(0)
  await shot(page, layer, "rebooting")
})

test("a mac-vz box's cache VM, its update, and Reboot cache VM", async ({page}) => {
  await signIn(page)
  await openBox(page, "m1ultra")
  const panel = page.locator("#cache-vm")
  await expect(panel).toContainText("flatcar-4800.0.0")
  await expect(panel).toContainText("sudo crew-box reimage crew-m1ultra-cachevm-reprovision.ign cachevm")
  await shot(page, layer, "cache-vm")
  await setTheme(page, "dark")
  await shot(page, layer, "cache-vm-dark")
  await setTheme(page, "light")

  page.once("dialog", d => d.accept())
  await page.locator("#reboot-cache-vm").click()
  await expect(panel).toContainText("Restarting")
  await shot(page, layer, "cache-vm-restarting")
})
