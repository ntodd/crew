import { defineConfig, devices } from "@playwright/test"

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
    baseURL: "http://localhost:4100",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } }],
  webServer: [
    {
      command: "node fake-github/server.mjs",
      url: "http://localhost:4199/__fake/state",
      env: { PORT: "4199", CREW_BASE: "http://localhost:4100" },
      reuseExistingServer: false,
    },
    {
      command: "./crew-server.sh",
      url: "http://localhost:4100/healthz",
      timeout: 240_000,
      reuseExistingServer: false,
      stdout: "pipe",
    },
  ],
})
