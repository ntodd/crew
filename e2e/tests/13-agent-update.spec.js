// Agent updates, for real (§20.2): a box enrolls running a real agent
// release (0.9.0, the null driver) from its data directory, the way
// launchd runs it on a Mac (agent/current/bin/crew-launch, restarted when
// it exits), and the control plane updates it to the newest release
// (0.9.1): it checks the signature, downloads, unpacks beside 0.9.0,
// swaps current and exits, and comes back on 0.9.1. Then an admin pins a
// release that crashes at start (0.9.2-rc.1): crew-launch rolls it back
// after three starts, 0.9.1 reports the failure, and after the second
// the version isn't sent again. Builds two releases first (a few minutes
// the first time; kept in tmp/e2e/agent-update), so it runs only with
// E2E_AGENT_UPDATE=1:
//
//   E2E_AGENT_UPDATE=1 npx playwright test tests/13-agent-update.spec.js
import { execFileSync, spawn } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync } from "node:fs"
import { resolve } from "node:path"
import { expect, test } from "@playwright/test"
import { addBox, shot, signIn } from "./helpers.js"

const layer = "13-releases"
const root = resolve(import.meta.dirname, "../..")
const releases = resolve(root, "tmp/e2e/agent-release")
const data = resolve(root, "tmp/e2e/agent-updbox")
const agentDir = resolve(data, "agent")
let launcher

test.describe.configure({ mode: "serial" })
test.skip(!process.env.E2E_AGENT_UPDATE, "set E2E_AGENT_UPDATE=1 (builds two agent releases)")

test.afterAll(() => {
  if (launcher && launcher.exitCode === null) {
    try { process.kill(-launcher.pid, "SIGTERM") } catch (_e) {}
  }
})

const key = () =>
  readFileSync(resolve(root, "images/guest/keys/test-signing.pub"), "utf8")
    .split("\n")
    .filter(l => !l.startsWith("#"))
    .join("")
    .trim()

// The first install, as install-macos.sh leaves it: agent/0.9.0 and
// current pointing at it.
function install(version) {
  rmSync(data, { recursive: true, force: true })
  mkdirSync(resolve(agentDir, version), { recursive: true })
  execFileSync("tar", ["-xzf", resolve(releases, `crew-agent-${version}-darwin-arm64.tar.gz`), "-C", resolve(agentDir, version)])
  symlinkSync(version, resolve(agentDir, "current"))
}

// launchd's KeepAlive: crew-launch from whatever current is, again
// whenever it exits.
function launch(token) {
  const child = spawn("sh", ["-c", 'while :; do "$CREW_DATA_DIR/agent/current/bin/crew-launch"; sleep 1; done'], {
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      CREW_URL: "ws://localhost:4100/agent/websocket",
      CREW_JOIN_TOKEN: token,
      CREW_BOX_NAME: "updbox",
      CREW_DATA_DIR: data,
      CREW_DRIVER: "null",
      CREW_DEV: "1",
      CREW_GUEST_API_PORT: "0",
      CREW_RELEASE_PUBLIC_KEY: key(),
      RELEASE_DISTRIBUTION: "none",
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  })
  const log = d => process.env.E2E_AGENT_LOG && process.stdout.write(`[updbox] ${d}`)
  child.stdout.on("data", log)
  child.stderr.on("data", log)
  return child
}

test("a box updates to the newest release, and a release that crashes is rolled back", async ({ page }) => {
  test.setTimeout(600_000)
  await signIn(page)

  // Both real releases and the crashing one are registered; 0.9.1 is
  // the newest boxes follow (prereleases only by a pin).
  install("0.9.0")
  const token = await addBox(page, "updbox")
  launcher = launch(token)

  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", { hasText: "updbox" })
  await expect(card).toContainText("Online", { timeout: 120_000 })
  await card.click()
  await expect(page.locator("#agent-target")).toContainText("0.9.1")

  // It joined on 0.9.0, got agent.update, and came back on 0.9.1.
  await expect(page.locator("#agent-running")).toContainText("0.9.1", { timeout: 180_000 })
  await expect(page.locator("#agent-update-state")).toContainText("Up to date")
  await expect(page.locator("#operations")).toContainText("Update agent")
  await expect(page.locator("#operations")).toContainText("succeeded")
  await shot(page, layer, "box-updated")

  expect(readlinkSync(resolve(agentDir, "current"))).toBe("0.9.1")
  // Joined: nothing pending, nothing to go back to, 0.9.0 pruned.
  await expect.poll(() => existsSync(resolve(agentDir, "update-pending"))).toBe(false)
  expect(existsSync(resolve(agentDir, "previous"))).toBe(false)
  await expect.poll(() => existsSync(resolve(agentDir, "0.9.0"))).toBe(false)

  // An admin pins the release that crashes at start.
  await page.locator("#pin-agent-version").selectOption("0.9.2-rc.1")
  await page.locator("#pin-agent").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#flash-info")).toContainText("Pinned updbox")
  await expect(page.locator("#agent")).toContainText("Pinned to")
  await shot(page, layer, "box-pinned")

  // crew-launch rolls it back after three starts; 0.9.1 says so, gets it
  // again, and after the second failure it isn't sent again.
  await expect(page.locator("#agent-update-failed")).toContainText("didn't take on this box twice", { timeout: 240_000 })
  await expect(page.locator("#agent-update-failed")).toContainText("0.9.2-rc.1")
  await expect(page.locator("#agent-running")).toContainText("0.9.1")
  await expect(page.locator("#operations")).toContainText("back on 0.9.1")
  await shot(page, layer, "box-update-failed-twice")
  expect(readlinkSync(resolve(agentDir, "current"))).toBe("0.9.1")

  // Following the newest again: the box is on it.
  await page.locator("#pin-agent-version").selectOption("")
  await page.locator("#pin-agent").getByRole("button", { name: "Save" }).click()
  await expect(page.locator("#agent-update-failed")).toHaveCount(0)
  await expect(page.locator("#agent-update-state")).toContainText("Up to date")
  await expect(page.locator("#agent")).toContainText("Follows")
  await shot(page, layer, "box-following")

  // Each pin is audited.
  await page.goto("/admin/audit")
  await expect(page.locator("main")).toContainText("box.pin_agent_version")
  await shot(page, layer, "audit")
})
