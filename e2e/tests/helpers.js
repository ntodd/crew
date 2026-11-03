import { mkdirSync } from "node:fs"
import { resolve } from "node:path"

export const fake = "http://localhost:4199"

// Screenshots for the PR, in tmp/shots/<layer>/.
export async function shot(page, layer, name, { fullPage = true } = {}) {
  const dir = resolve(import.meta.dirname, "../../tmp/shots", layer)
  mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: resolve(dir, `${name}.png`), fullPage })
}

export async function setTheme(page, theme) {
  await page.evaluate(t => {
    localStorage.setItem("phx:theme", t)
    document.documentElement.setAttribute("data-theme", t)
  }, theme)
}

export async function fakeState(request) {
  return (await request.get(`${fake}/__fake/state`)).json()
}

export async function fakePost(request, path, data = {}) {
  const resp = await request.post(`${fake}${path}`, { data })
  if (!resp.ok()) throw new Error(`${path}: ${resp.status()} ${await resp.text()}`)
  return resp.json()
}

// The fake GitHub authorizes at once, so signing in is one click.
export async function signIn(page) {
  await ensureSetUp(page)
  await page.goto("/sign-in")
  await page.getByRole("link", { name: "Continue with GitHub" }).click()
  await page.waitForURL(url => !url.pathname.startsWith("/sign-in"))
}

// Runs first-run setup through the browser if this deployment hasn't
// been set up yet, so each spec file can run on its own.
export async function ensureSetUp(page, host = "crew.tail1234.ts.net") {
  await page.goto("/setup")
  if (!(await page.getByLabel("Setup token").isVisible().catch(() => false))) return
  await page.getByLabel("Setup token").fill("e2e-setup-token-0123456789")
  await page.getByRole("button", { name: "Verify" }).click()
  await page.getByLabel("Tailnet host").fill(host)
  await page.getByRole("button", { name: "Continue" }).click()
  await page.getByRole("button", { name: "Continue on GitHub" }).click()
  await page.getByRole("button", { name: /Create GitHub App/ }).click()
  await page.getByRole("button", { name: "Install" }).click()
  await page.waitForURL(/\/sign-in$/)
}
