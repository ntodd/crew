// A fresh deployment, end to end in the browser: the setup token, the
// tailnet host, Crew's App manifest on (fake) GitHub, installing it, and
// the first sign-in, which makes that person the admin.
import { expect, test } from "@playwright/test"
import { fakeState, setTheme, shot } from "./helpers.js"

const layer = "02-control-plane"
const host = "crew.tail1234.ts.net"

test.describe.configure({ mode: "serial" })

test("first run: setup, create the App, install it, sign in", async ({ page, request }) => {
  await page.goto("/setup")
  await expect(page.getByLabel("Setup token")).toBeVisible()
  await shot(page, layer, "setup-token")

  await page.getByLabel("Setup token").fill("not-the-token")
  await page.getByRole("button", { name: "Verify" }).click()
  await expect(page.getByText("That setup token isn't right")).toBeVisible()

  await page.getByLabel("Setup token").fill("e2e-setup-token-0123456789")
  await page.getByRole("button", { name: "Verify" }).click()

  // A host with a scheme is refused, and the form comes back.
  await page.getByLabel("Tailnet host").fill(`https://${host}`)
  await page.getByRole("button", { name: "Continue" }).click()
  await expect(page.getByText("The tailnet host must be a host name")).toBeVisible()

  await page.getByLabel("Tailnet host").fill(host)
  await shot(page, layer, "setup-host")
  await page.getByRole("button", { name: "Continue" }).click()

  await expect(page.getByRole("heading", { name: "Create the GitHub App" })).toBeVisible()
  await expect(page.getByText("Administration (write)")).toBeVisible()
  await shot(page, layer, "setup-manifest")
  await page.getByRole("button", { name: "Continue on GitHub" }).click()

  // On GitHub: the manifest GitHub received is Crew's.
  await expect(page.locator("#app-name")).toHaveText(/^Crew \([a-z0-9]{4}\)$/)
  await expect(page.locator("#hook-url")).toHaveText(`https://${host}:8443/hooks/github`)
  await expect(page.locator("#events")).toHaveText("workflow_job, workflow_run")

  const state = await fakeState(request)
  const manifest = Object.values(state.manifests)[0]
  expect(manifest.default_permissions).toEqual({
    administration: "write",
    actions: "write",
    metadata: "read",
    pull_requests: "read",
    members: "read",
  })
  expect(manifest.redirect_url).toBe(`https://${host}/setup/github/callback`)
  expect(manifest.callback_urls).toEqual([`https://${host}/auth/github/callback`])
  expect(manifest.setup_url).toBe(`https://${host}/setup/github/installed`)
  expect(manifest.public).toBe(false)

  await page.getByRole("button", { name: /Create GitHub App/ }).click()

  // Crew stored the credentials and sent us to install the App.
  await expect(page.getByRole("heading", { name: /^Install Crew/ })).toBeVisible()
  await page.getByRole("button", { name: "Install" }).click()

  await expect(page).toHaveURL(/\/sign-in$/)
  await expect(page.getByText("Installed. Sign in to continue.")).toBeVisible()
  await shot(page, layer, "sign-in")

  // Setup is closed now that the App exists.
  await page.goto("/setup")
  await expect(page).toHaveURL(/\/sign-in$/)

  await page.getByRole("link", { name: "Continue with GitHub" }).click()
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
  await expect(page.locator("#empty-boxes")).toContainText("Add your first box")
  await expect(page.locator("#empty-jobs")).toContainText("runs-on: crew-m")

  // The first person in is the admin.
  await expect(page.getByRole("link", { name: "Deployment" })).toBeVisible()
  await shot(page, layer, "dashboard-light")
  await setTheme(page, "dark")
  await shot(page, layer, "dashboard-dark")
  await setTheme(page, "light")

  await page.getByRole("link", { name: "Deployment" }).click()
  await expect(page.locator("#deployment-id")).toHaveText(/^[a-z0-9]{4}$/)
  await expect(page.locator("#funnel-url")).toHaveText(`https://${host}:8443/hooks/github`)
  await expect(page.locator("#deployment-github")).toContainText("Connected")
  await shot(page, layer, "deployment")

  await page.getByRole("link", { name: "People" }).click()
  await expect(page.getByRole("heading", { name: "People" })).toBeVisible()
  await expect(page.locator("main").getByText("mona", { exact: true })).toBeVisible()
  await shot(page, layer, "people")
})

test("the dashboard is usable at 360 px", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 })
  await page.goto("/sign-in")
  await page.getByRole("link", { name: "Continue with GitHub" }).click()
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  expect(overflow).toBeLessThanOrEqual(0)
  await shot(page, layer, "dashboard-narrow")
})
