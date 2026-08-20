// E2E config. Runs from the host against this worktree's Docker dev
// stack; ports come from ../.dev-ports.json (never assume 4000/8080 —
// parallel worktrees bind different slots).
const fs = require('fs');
const path = require('path');
const { defineConfig } = require('@playwright/test');

const ports = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, '..', '.dev-ports.json'), 'utf8'),
).ports;

module.exports = defineConfig({
  testDir: './tests',
  // One synthetic player driving one game instance — parallelism would
  // just make the scenarios fight over it.
  workers: 1,
  fullyParallel: false,
  // The scenario waits on real game ticks (Flash speed: 1 ut ≈ 1.5 s).
  timeout: 10 * 60 * 1000,
  expect: { timeout: 30 * 1000 },
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${ports.phoenix}`,
    viewport: { width: 1440, height: 900 },
    // On failure we want the trail.
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});

module.exports.PHOENIX_PORT = ports.phoenix;
