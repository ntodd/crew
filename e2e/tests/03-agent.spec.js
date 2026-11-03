// A box end to end: Add box makes a join token, an agent (the null
// driver, §11.5) enrolls with it over the signed socket, and the box is
// online with its capabilities and live metrics.
import { generateKeyPairSync } from "node:crypto"
import { expect, test } from "@playwright/test"
import { addBox, shot, signIn, startAgent, stopAgent } from "./helpers.js"

const layer = "04-agent"
let agent
let spentToken

test.describe.configure({ mode: "serial" })
test.afterAll(() => stopAgent(agent))

test("a box enrolls, joins and reports", async ({ page }) => {
  test.setTimeout(240_000)
  await signIn(page)

  await page.goto("/boxes")
  await expect(page.locator("#boxes-empty")).toContainText("Add your first box")
  await shot(page, layer, "boxes-empty")

  const token = await addBox(page, "devnull")
  spentToken = token
  await expect(page.locator("#join-command")).toContainText("install-macos.sh")
  await expect(page.locator("#dev-join-command")).toContainText(token)
  await shot(page, layer, "add-box")

  agent = startAgent(token, { name: "devnull" })

  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", { hasText: "devnull" })
  await expect(card).toBeVisible()
  await expect(card).toContainText("Online", { timeout: 180_000 })
  await expect(card).toContainText("null")
  await shot(page, layer, "boxes")

  await card.click()
  await expect(page.locator("#capabilities")).toContainText("null")
  await expect(page.locator("#capabilities")).toContainText("Firewall verified")
  // box.metrics every 5 s; the page updates live.
  await expect(page.locator("#metrics")).toContainText("VMs running", { timeout: 20_000 })
  await expect(page.locator("#inventory")).toContainText("No VMs or images")
  await shot(page, layer, "box")
})

test("the join token was single use", async ({ request }) => {
  // The agent's token, replayed with a perfectly good key of another machine.
  const der = generateKeyPairSync("ed25519").publicKey.export({ format: "der", type: "spki" })
  const publicKey = der.subarray(der.length - 32).toString("base64")
  const resp = await request.post("/api/agents/enroll", { data: { join_token: spentToken, public_key: publicKey } })
  expect(resp.status()).toBe(401)
})

test("an agent that stops goes offline", async ({ page }) => {
  await signIn(page)
  stopAgent(agent)
  await page.goto("/boxes")
  const card = page.locator("[id^=box-]", { hasText: "devnull" })
  await expect(card).toContainText("Offline", { timeout: 30_000 })
})
