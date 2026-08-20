// One-off visual capture of the armada grouping matrix in the system
// view, on both agent displays. The fixture pre-forms every case:
// two OWN armadas (2+2, one solo navarch spare), one same-faction
// (friendly) armada, and one hostile trio — all standing in the
// caller's starting system. Produces PNGs under e2e/screens/.
// Not part of the regression suite — run explicitly:
//   ARMADA_SCREENS=1  then  bin/e2e.ps1 -Grep screens
const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, openSystem,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const OUT = path.resolve(__dirname, '..', 'screens');

test.skip(!process.env.ARMADA_SCREENS, 'screenshot capture only runs with ARMADA_SCREENS=1');

async function capture(page, name) {
  await page.waitForTimeout(1500); // let the fade-in settle
  await page.screenshot({ path: path.join(OUT, `${name}.png`) });
}

// Zoomed crop around the elements matching `selector` (union + padding).
async function captureCrop(page, selector, name, pad = 100) {
  const boxes = await page.$$eval(selector, (els) => els.map((el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  }));
  const vis = boxes.filter((b) => b.w > 0 && b.h > 0);
  if (!vis.length) return false;
  const x0 = Math.max(0, Math.min(...vis.map((b) => b.x)) - pad);
  const y0 = Math.max(0, Math.min(...vis.map((b) => b.y)) - pad);
  const x1 = Math.max(...vis.map((b) => b.x + b.w)) + pad;
  const y1 = Math.max(...vis.map((b) => b.y + b.h)) + pad;
  await page.screenshot({
    path: path.join(OUT, `${name}.png`),
    clip: { x: x0, y: y0, width: x1 - x0, height: y1 - y0 },
  });
  return true;
}

async function driveViews(browser, api, baseURL, features, label) {
  const fixture = await api.createAgentFixture(
    PLAYER.email,
    null,
    features,
    5,
    { own: [2, 2], friendly: [2], hostile: [3] },
  );
  const instanceId = fixture.instance_id;
  const systemId = fixture.system.id;

  const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  const page = await context.newPage();

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);
    await page.goto('/portal/game');
    await waitConnected(page);
    await openSystem(page, systemId);

    await capture(page, `matrix-${label}-full`);

    if (label === 'fan') {
      // two own bands on the inner ring
      await captureCrop(page, '.system-actions .armada-links path', 'matrix-fan-own-bands');
      // collapsed stacks (friendly + hostile clusters wear capsules) —
      // match the icons/capsules, the .cluster div itself is 0-sized
      await captureCrop(page, '.cluster .round-icon, .cluster .armada-capsule', 'matrix-fan-clusters-collapsed');

      // unfurl each cluster in turn: the armada members band together
      const clusters = page.locator('.cluster .round-icon');
      const count = await clusters.count();
      for (let i = 0; i < Math.min(count, 3); i += 1) {
        await clusters.nth(i).click();
        await page.waitForTimeout(800);
        const shot = await captureCrop(
          page,
          '.cluster-fan .agent-badge .round-icon, .cluster-fan .armada-links-px path',
          `matrix-fan-unfurl-${i + 1}`,
          130,
        );
        if (!shot) await capture(page, `matrix-fan-unfurl-${i + 1}`);
        await page.mouse.click(400, 900); // close the pinned fan
        await page.waitForTimeout(400);
      }
    } else {
      // the legacy arc: own + friendly + hostile bands in one sweep
      await captureCrop(page, '.armada-links-legacy path', 'matrix-legacy-bands', 130);
    }
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
    await context.close();
  }
}

test('capture the armada grouping matrix on both displays', async ({ browser, request, baseURL }) => {
  test.setTimeout(8 * 60 * 1000);
  fs.mkdirSync(OUT, { recursive: true });

  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  await driveViews(browser, api, baseURL, ['agent_fan_display'], 'fan');
  await driveViews(browser, api, baseURL, [], 'legacy');
});
