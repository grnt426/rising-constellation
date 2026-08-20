// One-off visual capture: armadas of 2 and 3 in the system view, on
// both agent displays (beta fan + legacy). Produces PNGs under
// e2e/screens/. Not part of the regression suite — run explicitly:
//   pwsh bin/e2e.ps1 -Grep screens
const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, openSystem, playerPush,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const OUT = path.resolve(__dirname, '..', 'screens');

test.skip(!process.env.ARMADA_SCREENS, 'screenshot capture only runs with ARMADA_SCREENS=1');

function ownAdmiralIds(page) {
  return page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return (st.player.characters || [])
      .filter((c) => c.type === 'admiral' && c.status === 'on_board')
      .map((c) => c.id);
  });
}

async function armadaSizeOnRoster(page) {
  return page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const sizes = (st.player.characters || [])
      .filter((c) => c.armada)
      .map((c) => c.armada.member_ids.length);
    return sizes.length ? Math.max(...sizes) : 0;
  });
}

async function capture(page, name) {
  await page.waitForTimeout(1500); // let the fade-in/tooltips settle
  await page.screenshot({ path: path.join(OUT, `${name}.png`) });
}

// Zoomed crop around the elements matching `selector` (union + padding).
async function captureCrop(page, selector, name, pad = 90) {
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

async function driveViews(browserContextFactory, api, baseURL, features, label) {
  const fixture = await api.createAgentFixture(PLAYER.email, null, features, 3);
  const instanceId = fixture.instance_id;
  const systemId = fixture.system.id;

  const { context, page } = await browserContextFactory();

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);
    await page.goto('/portal/game');
    await waitConnected(page);

    const [a1, a2, a3] = await ownAdmiralIds(page);

    // match the band + count chip (real boxes — the fan's .orbit-item
    // anchors are 0x0 points, so container-level matches filter out)
    const memberSelector = label === 'fan'
      ? '.system-actions .armada-count, .system-actions .armada-links path'
      : '.system-actions-legacy .armada-count, .system-actions-legacy .armada-band';

    // pair
    const form = await playerPush(page, 'form_armada', { character_id: a1, other_character_id: a2 });
    expect(form.ok, `form failed: ${form.error}`).toBe(true);
    await expect.poll(() => armadaSizeOnRoster(page)).toBe(2);
    await openSystem(page, systemId);
    await capture(page, `armada-2-${label}`);
    await captureCrop(page, memberSelector, `armada-2-${label}-closeup`);

    // trio
    const join = await playerPush(page, 'join_armada', { character_id: a3, armada_character_id: a1 });
    expect(join.ok, `join failed: ${join.error}`).toBe(true);
    await expect.poll(() => armadaSizeOnRoster(page)).toBe(3);
    await capture(page, `armada-3-${label}`);
    await captureCrop(page, memberSelector, `armada-3-${label}-closeup`);

    // enemy squadron fan-out (fan display only): armada data is
    // owner-only, so a hostile armada's unfurl is bit-identical to any
    // squadron's — this shot documents exactly that
    if (label === 'fan') {
      const cluster = page.locator('.cluster .round-icon').first();
      if (await cluster.count()) {
        await cluster.click();
        await page.waitForTimeout(800);
        await captureCrop(page, '.cluster, .cluster-fan .agent-badge .round-icon', 'enemy-cluster-fan', 120);
        await page.mouse.click(10, 500); // close the pinned fan
      }
    }
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
    await context.close();
  }
}

test('capture armada system-view screens on both displays', async ({ browser, request, baseURL }) => {
  test.setTimeout(8 * 60 * 1000);
  fs.mkdirSync(OUT, { recursive: true });

  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const makeCtx = async () => {
    const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
    const page = await context.newPage();
    return { context, page };
  };

  // beta fan display
  await driveViews(makeCtx, api, baseURL, ['agent_fan_display'], 'fan');
  // regular (legacy) display
  await driveViews(makeCtx, api, baseURL, [], 'legacy');
});
