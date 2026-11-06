import { mkdirSync } from "node:fs"
import { resolve } from "node:path"

export const fake = "http://localhost:4199"

// Screenshots for the PR, in tmp/shots/<layer>/.
export async function shot(page, layer, name, { fullPage = true } = {}) {
  const dir = resolve(import.meta.dirname, "../../tmp/shots", layer)
  mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: resolve(dir, `${name}.png`), fullPage })
}

// Waits out the color transitions the switch starts, so a screenshot
// right after it isn't caught halfway between the themes. Only the
// transitions: a running job's pulsing dot is an animation that never
// finishes.
export async function setTheme(page, theme) {
  await page.evaluate(async t => {
    localStorage.setItem("phx:theme", t)
    document.documentElement.setAttribute("data-theme", t)
    const transitions = document.getAnimations().filter(a => a instanceof CSSTransition)
    await Promise.all(transitions.map(a => a.finished.catch(() => {})))
  }, theme)
}

// A LiveView ignores clicks and form changes until its socket is up,
// which on a slow machine can be well after the page has loaded.
export async function connected(page) {
  await page.locator("[data-phx-main].phx-connected").waitFor()
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

// Starts a null-driver agent (apps/crew_agent, dev) enrolled with `token`.
// Returns the child process; call stopAgent() when done.
import { spawn, spawnSync } from "node:child_process"

function hasMise() {
  return spawnSync("sh", ["-c", "command -v mise"], { stdio: "ignore" }).status === 0
}
import { rmSync } from "node:fs"

export function startAgent(token, { name, dataDir, env = {}, keepDir = false } = {}) {
  const root = resolve(import.meta.dirname, "../..")
  const dir = dataDir || resolve(root, "tmp/e2e/agent-" + name)
  if (!keepDir) rmSync(dir, { recursive: true, force: true })
  // mise pins the toolchain locally; CI sets it up directly.
  const [cmd, args] = hasMise() ? ["mise", ["exec", "--", "mix", "run", "--no-halt"]] : ["mix", ["run", "--no-halt"]]
  const child = spawn(cmd, args, {
    cwd: resolve(root, "apps/crew_agent"),
    env: {
      ...process.env,
      MIX_ENV: "dev",
      CREW_DEV: "1",
      CREW_DRIVER: "null",
      // The suite (and its screenshots) assume an arm64 box.
      CREW_NULL_GUEST_ARCH: "arm64",
      CREW_URL: "ws://localhost:4100/agent/websocket",
      CREW_JOIN_TOKEN: token,
      CREW_BOX_NAME: name,
      CREW_DATA_DIR: dir,
      CREW_GUEST_API_PORT: "0",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  })
  child.stdout.on("data", d => process.env.E2E_AGENT_LOG && process.stdout.write(`[agent ${name}] ${d}`))
  child.stderr.on("data", d => process.env.E2E_AGENT_LOG && process.stdout.write(`[agent ${name}] ${d}`))
  return child
}

export function stopAgent(child) {
  if (!child || child.exitCode !== null) return
  try { process.kill(-child.pid, "SIGTERM") } catch (_e) {}
}

export async function addBox(page, name, type = "mac-vz") {
  await page.goto("/boxes/new")
  await connected(page)
  await page.getByLabel("Name").fill(name)
  await page.locator(`input[name="box[box_type]"][value="${type}"]`).check()
  await page.getByRole("button", { name: "Create join token" }).click()
  const text = await page.locator("#dev-join-command, #join-command").first().innerText()
  return text.match(/(cj_[A-Za-z0-9_-]+)/)[1]
}

// Content that spills out of its table cell (a status running into the
// next column): each cell's descendants must end inside it. Returns the
// offenders, as text, for the assertion message.
export async function cellOverflows(page, rows) {
  return page.locator(rows).evaluateAll(trs => {
    const out = []
    for (const tr of trs) {
      for (const td of tr.querySelectorAll("td")) {
        const edge = td.getBoundingClientRect().right
        for (const el of td.querySelectorAll("*")) {
          const r = el.getBoundingClientRect()
          if (r.width > 0 && r.right > edge + 1) out.push(`${tr.id}: "${el.textContent.trim().slice(0, 60)}" ends ${Math.round(r.right - edge)}px past its cell`)
        }
      }
    }
    return [...new Set(out)]
  })
}
