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
