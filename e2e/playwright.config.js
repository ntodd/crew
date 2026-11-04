import { defineConfig, devices } from "@playwright/test"

// E2E_BASE_URL moves the control plane off loopback, e.g. to a Mac's
// vmnet bridge (http://192.168.64.1:4100) so a Flatcar VM can reach it.
const base = process.env.E2E_BASE_URL || "http://localhost:4100"

// The control plane and the fake GitHub, both started fresh for the run.
export default defineConfig({
  testDir: "./tests",
  outputDir: "../tmp/e2e/results",
  fullyParallel: false,
  workers: 1,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: {
    baseURL: base,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } }],
  webServer: [
    {
      command: "node fake-github/server.mjs",
      url: "http://localhost:4199/__fake/state",
      env: { PORT: "4199", CREW_BASE: base, CREW_HOOK: "http://127.0.0.1:4101/hooks/github" },
      reuseExistingServer: false,
    },
    {
      command: "./crew-server.sh",
      url: `${base}/healthz`,
      // E2E_AGENT_UPDATE builds two agent releases first (13-agent-update).
      timeout: process.env.E2E_AGENT_UPDATE ? 900_000 : 240_000,
      reuseExistingServer: false,
      stdout: "pipe",
    },
  ],
})
