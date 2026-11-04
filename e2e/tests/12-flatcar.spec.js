// Flatcar boxes (§12.2, §12.3) in a real browser, under production's
// style policy: Add box for linux-vm, mac-vm and linux-metal, the
// launcher and Ignition the control plane serves for a join token, the
// Ignition download, and the box page's reprovision Ignition. The
// release the Ignition names is crew-server.sh's placeholder one, signed
// with the development key.
import {expect, test} from "@playwright/test"
import {randomBytes} from "node:crypto"
import {readFileSync} from "node:fs"
import {shot, signIn} from "./helpers.js"

const layer = "12-flatcar"
const breakGlass = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlassE2E admin@laptop"

test.describe.configure({mode: "serial"})

function watchCsp(page) {
  const violations = []
  page.on("console", m => {
    if (m.type() === "error" && /Content Security Policy/i.test(m.text())) violations.push(m.text())
  })
  return violations
}

function decode(file) {
  return Buffer.from(file.contents.source.replace(/^data:;base64,/, ""), "base64").toString()
}

function files(ign) {
  return Object.fromEntries(ign.storage.files.map(f => [f.path, f]))
}

function unit(ign, name) {
  return ign.systemd.units.find(u => u.name === name)
}

async function fitsWidth(page) {
  return page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
}

// 360 px, once the sidebar has slid away into its drawer.
async function toMobile(page) {
  await page.setViewportSize({width: 360, height: 800})
  await expect
    .poll(() => page.locator("#app-sidebar").evaluate(el => el.getBoundingClientRect().right))
    .toBeLessThanOrEqual(0)
}

async function startAdding(page, name, type) {
  await page.goto("/boxes/new")
  await page.getByLabel("Name").fill(name)
  await page.locator(`input[name="box[box_type]"][value="${type}"]`).check()
}

test("linux-vm: the launcher's one command, and the Ignition it fetches", async ({page, request}) => {
  const violations = watchCsp(page)
  await signIn(page)
  await startAdding(page, "desk1", "linux-vm")

  // A Flatcar box's own fields: a break-glass key, and (with no
  // Tailscale OAuth client here) a pasted auth key. No data disk: the
  // launcher gives the VM /dev/vdb.
  await expect(page.locator("#box_ssh_keys")).toBeVisible()
  await expect(page.locator("#box_tailscale_auth_key")).toBeVisible()
  await expect(page.locator("#box_data_disk")).toHaveCount(0)
  await page.locator("#box_ssh_keys").fill(breakGlass)
  await shot(page, layer, "add-box-linux-vm")

  await page.getByRole("button", {name: "Create join token"}).click()
  const command = await page.locator("#join-command").innerText()
  expect(command).toMatch(/^curl -fsSL http:\/\/localhost:4100\/agent\/linux-vm\.sh \| sudo sh -s -- --token cj_/)
  await expect(page.locator("#join-instructions")).toContainText("--data GiB")
  await shot(page, layer, "linux-vm-command")

  // The launcher that command runs, with the release's Flatcar pinned.
  const script = await (await request.get("/agent/linux-vm.sh")).text()
  expect(script).toContain('CREW_URL="http://localhost:4100"')
  expect(script).toMatch(/FLATCAR_VERSION="\d+\.\d+\.\d+"/)
  expect(script).toMatch(/FLATCAR_IMAGE_SHA512_AMD64="[0-9a-f]{128}"/)

  // What the launcher asks for first: the box's Ignition, for the token.
  const token = command.match(/(cj_[A-Za-z0-9_-]+)/)[1]
  const resp = await request.post("/agent/flatcar/ignition", {
    form: {join_token: token, arch: "amd64", "ssh_keys[]": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILauncherE2E crew-box@host"},
  })
  expect(resp.status()).toBe(200)
  expect(resp.headers()["x-crew-box"]).toBe("desk1")
  const ign = await resp.json()
  expect(ign.ignition.version).toBe("3.4.0")
  const f = files(ign)
  expect(decode(f["/etc/hostname"])).toBe("desk1\n")
  expect(f["/etc/crew-box/provision.env"].mode).toBe(0o600)
  expect(decode(f["/etc/crew-box/provision.env"])).toContain(`CREW_JOIN_TOKEN="${token}"`)
  // Development: the tarballs come from this control plane, over ws://.
  const release = decode(f["/etc/crew-box/release.env"])
  expect(release).toContain('CREW_AGENT_URL="http://localhost:4100/agent/releases/0.9.0/linux-amd64/crew-agent-0.9.0-linux-amd64.tar.gz"')
  expect(release).toContain('CREW_AGENT_SOCKET_URL="ws://localhost:4100/agent/websocket"')
  expect(unit(ign, "crew-format-data.service").contents).toContain("format-data.sh /dev/vdb")
  const core = ign.passwd.users.find(u => u.name === "core")
  expect(core.sshAuthorizedKeys).toEqual([breakGlass, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILauncherE2E crew-box@host"])

  // The tarball it names is there.
  const tarball = await request.get("/agent/releases/0.9.0/linux-amd64/crew-agent-0.9.0-linux-amd64.tar.gz")
  expect(tarball.status()).toBe(200)
  expect(tarball.headers()["x-crew-sha256"]).toMatch(/^[0-9a-f]{64}$/)

  // A bad token is refused, and counts like a failed enrollment.
  const bad = await request.post("/agent/flatcar/ignition", {form: {join_token: "cj_nope", arch: "amd64"}})
  expect(bad.status()).toBe(401)
  expect(violations).toEqual([])
})

test("mac-vm: the launcher's one command", async ({page, request}) => {
  const violations = watchCsp(page)
  await signIn(page)
  await startAdding(page, "studio", "mac-vm")
  await page.getByRole("button", {name: "Create join token"}).click()
  await expect(page.locator("#join-command")).toContainText("/agent/mac-vm.sh | sudo sh -s -- --token cj_")

  const script = await (await request.get("/agent/mac-vm.sh")).text()
  expect(script).toContain("--nested")
  expect(script).toMatch(/VFKIT_SHA256="[0-9a-f]{64}"/)

  await toMobile(page)
  expect(await fitsWidth(page)).toBe(true)
  await shot(page, layer, "mac-vm-command-mobile")
  expect(violations).toEqual([])
})

test("linux-metal: the data disk, then the Ignition to download", async ({page}) => {
  const violations = watchCsp(page)
  await signIn(page)
  await startAdding(page, "rack1", "linux-metal")
  await expect(page.locator("#box_data_disk")).toBeVisible()

  // The data disk is needed.
  await page.getByRole("button", {name: "Create join token"}).click()
  await expect(page.locator("#add-box")).toContainText("is needed for a dedicated Linux machine")
  await page.locator("#box_data_disk").fill("/dev/nvme1n1")
  await page.locator("#box_ssh_keys").fill(breakGlass)
  await shot(page, layer, "add-box-linux-metal")

  await toMobile(page)
  expect(await fitsWidth(page)).toBe(true)
  await shot(page, layer, "add-box-linux-metal-mobile")
  await page.setViewportSize({width: 1440, height: 900})

  await page.getByRole("button", {name: "Create join token"}).click()
  await expect(page.locator("#ignition-download")).toBeVisible()
  await expect(page.locator("#flatcar-install")).toContainText("flatcar-install -d /dev/sda -i crew-rack1.ign")
  await shot(page, layer, "linux-metal-ignition")

  await page.locator("#ignition-arch").selectOption("arm64")
  const [download] = await Promise.all([
    page.waitForEvent("download"),
    page.getByRole("button", {name: "Download Ignition"}).click(),
  ])
  expect(download.suggestedFilename()).toBe("crew-rack1-arm64.ign")
  const ign = JSON.parse(readFileSync(await download.path(), "utf8"))
  expect(ign.ignition.version).toBe("3.4.0")
  expect(decode(files(ign)["/etc/hostname"])).toBe("rack1\n")
  expect(decode(files(ign)["/etc/crew-box/release.env"])).toContain('CREW_TARGET="linux-arm64"')
  expect(unit(ign, "crew-format-data.service").contents).toContain("format-data.sh /dev/nvme1n1")
  // The download leaves the page as it was.
  await expect(page.locator("#join-instructions")).toBeVisible()

  await toMobile(page)
  expect(await fitsWidth(page)).toBe(true)
  await shot(page, layer, "linux-metal-ignition-mobile")
  expect(violations).toEqual([])
})

test("the box page's reprovision Ignition", async ({page, request}) => {
  const violations = watchCsp(page)
  await signIn(page)
  await startAdding(page, "studio2", "mac-vm")
  await page.getByRole("button", {name: "Create join token"}).click()
  const token = (await page.locator("#join-command").innerText()).match(/(cj_[A-Za-z0-9_-]+)/)[1]

  // The agent's own enrollment spends the token (with a made-up key).
  const enroll = await request.post("/api/agents/enroll", {
    data: {join_token: token, public_key: randomBytes(32).toString("base64")},
  })
  expect(enroll.status()).toBe(201)
  const {agent_id: id} = await enroll.json()

  await page.goto(`/boxes/${id}`)
  const panel = page.locator("#reprovision")
  await expect(panel).toContainText("sudo crew-box reimage crew-studio2-arm64-reprovision.ign")
  await shot(page, layer, "box-reprovision")

  const [download] = await Promise.all([
    page.waitForEvent("download"),
    panel.getByRole("button", {name: "Download Ignition"}).click(),
  ])
  expect(download.suggestedFilename()).toBe("crew-studio2-arm64-reprovision.ign")
  const ign = JSON.parse(readFileSync(await download.path(), "utf8"))
  const text = JSON.stringify(ign)
  expect(text).not.toContain("cj_")
  expect(files(ign)["/etc/crew-box/provision.env"]).toBeUndefined()
  expect(unit(ign, "crew-agent.service").enabled).toBe(true)

  await toMobile(page)
  await page.goto(`/boxes/${id}`)
  await expect(page.locator("#reprovision")).toBeVisible()
  expect(await fitsWidth(page)).toBe(true)
  await shot(page, layer, "box-reprovision-mobile")
  expect(violations).toEqual([])
})
