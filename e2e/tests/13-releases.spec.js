// Updating the control plane (§20.3) in a real browser, under
// production's style policy: the Deployment page's check of the fake
// GitHub's releases (a newer one, past a draft and a prerelease), the
// updater's install command, an admin's "Update to 0.2.0" writing the
// request crew-update takes, and the page following the updater's
// reports. The test plays the host's updater, writing the status/ that
// crew-server.sh's CREW_UPDATE_DIR shares with the control plane.
import {expect, test} from "@playwright/test"
import {existsSync, readFileSync, rmSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"
import {setTheme, shot, signIn} from "./helpers.js"

const layer = "13-releases"
const dir = resolve(import.meta.dirname, "../../tmp/e2e/update")

test.describe.configure({mode: "serial"})

function watchCsp(page) {
  const violations = []
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(m.text())
  })
  return violations
}

// What crew-update writes as it goes.
function report(state, message, extra = {}) {
  const at = new Date().toISOString().replace(/\.\d+Z$/, "Z")
  const body = {state, from: "0.1.0", to: "0.2.0", message, at, updater: 1, ...extra}
  writeFileSync(resolve(dir, "status/state.json"), JSON.stringify(body) + "\n")
}

test.beforeAll(() => {
  for (const f of ["request/version", "status/updater", "status/state.json"]) rmSync(resolve(dir, f), {force: true})
})

test("the newest release, and how to install the updater", async ({page}) => {
  const violations = watchCsp(page)
  await signIn(page)
  await page.goto("/admin")

  const panel = page.locator("#crew-update")
  await expect(panel).toContainText("Running Crew 0.1.0")
  await expect(panel).toContainText("checked daily")

  // At boot the control plane checked once already; Check now asks again.
  await page.locator("#check-for-updates").click()
  const available = page.locator("#crew-update-available")
  await expect(available).toContainText("Crew 0.2.0 is available")
  await expect(available.getByRole("link", {name: "Release notes"}))
    .toHaveAttribute("href", /\/ntodd\/crew\/releases\/tag\/v0\.2\.0$/)

  // No updater on this host yet: no button, but the one command that
  // installs it from the image the control plane runs.
  await expect(page.locator("#update-crew")).toHaveCount(0)
  await expect(page.locator("#install-updater-command")).toContainText("/app/updater/crew-update")
  await expect(page.locator("#install-updater-command")).toContainText("sh -s -- install /path/to/compose.yml")
  await shot(page, layer, "update-available-no-updater")
  expect(violations).toEqual([])
})

test("an admin updates, and the page follows the host's updater", async ({page}) => {
  const violations = watchCsp(page)
  writeFileSync(resolve(dir, "status/updater"), "1\n")
  await signIn(page)
  await page.goto("/admin")

  const panel = page.locator("#crew-update")
  const button = page.locator("#update-crew")
  await expect(button).toHaveText("Update to 0.2.0")
  await shot(page, layer, "update-available")

  page.once("dialog", dialog => {
    expect(dialog.message()).toContain("Update Crew to 0.2.0 and restart it?")
    dialog.accept()
  })
  await button.click()

  // The request is the version and nothing else, renamed into place.
  await expect(panel).toContainText("Waiting for the host's updater to pick up 0.2.0")
  await expect(button).toHaveCount(0)
  expect(readFileSync(resolve(dir, "request/version"), "utf8")).toBe("0.2.0\n")
  expect(existsSync(resolve(dir, "request/.version.tmp"))).toBe(false)
  await shot(page, layer, "update-pending")

  // The updater takes the request and reports; the page polls it.
  rmSync(resolve(dir, "request/version"))
  report("running", "Pulling ghcr.io/ntodd/crew:0.2.0.")
  await expect(panel).toContainText("Pulling ghcr.io/ntodd/crew:0.2.0.")
  await expect(panel).toContainText("Jobs keep running")
  await shot(page, layer, "update-running")

  // 0.2.0 never answered /healthz, so the updater put 0.1.0 back.
  report("rolled_back", "0.2.0 didn't come up healthy, so 0.1.0 is back with its data as it was. journalctl -u crew-update has its logs.")
  await expect(page.locator("#last-update")).toContainText("0.2.0 didn't come up healthy, so 0.1.0 is back")
  await expect(page.locator("#last-update")).toHaveClass(/text-danger/)
  // Still the newest and still newer, so it can be tried again.
  await expect(page.locator("#update-crew")).toHaveText("Update to 0.2.0")
  await shot(page, layer, "update-rolled-back")

  await setTheme(page, "dark")
  await shot(page, layer, "update-rolled-back-dark")
  await setTheme(page, "light")

  // Who asked, in the audit log.
  await page.goto("/admin/audit")
  const row = page.locator("tr", {hasText: "crew.update"})
  await expect(row).toContainText("from=0.1.0")
  await expect(row).toContainText("to=0.2.0")
  await expect(row).toContainText("mona")
  await shot(page, layer, "audit")
  expect(violations).toEqual([])
})

test("a narrow screen", async ({page}) => {
  await signIn(page)
  await page.setViewportSize({width: 360, height: 800})
  await page.goto("/admin")
  await expect(page.locator("#update-crew")).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)).toBe(true)
  await shot(page, layer, "update-mobile")
})
