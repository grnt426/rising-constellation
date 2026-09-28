// Construction-queue reordering (desktop drag-and-drop).
//
// Rules under test:
//   - Only the head of the queue accumulates production. Progress is NOT
//     carried across a reorder: a displaced head resets to its full cost.
//   - So no drag can make anything complete earlier than it would have in
//     that order from the start. In particular, dragging an expensive item
//     ahead of a cheap one that is about to finish must neither finish the
//     cheap one nor hand its progress to the expensive one.
//   - The server only accepts an exact permutation of the live queue;
//     stale or malformed orders are refused without touching it (and
//     without crashing the player agent).
//   - Ids stay unique after reorders, so cancel removes exactly one item.
//   - Constructions then complete in the new order.
//
// Server truth comes from get_system (which settles the system to "now");
// player-visible truth from the DOM of the real queue panel.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, counters, openSystem, playerPush, serverPlayer,
  setSpeedCheat, orderOneBuild, serverSystem,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const SPEEDS = [0.25, 0.5, 1, 2, 5, 10, 20, 50];

let api;
let instanceId;
let homeSystemId;
let speed = 1;

// At the config's 1440×900 the system view's left info panel covers the
// queue toggle (a pre-existing layout overlap); use a common 1080p desktop.
const DESKTOP = { width: 1920, height: 1080 };
test.use({ viewport: DESKTOP });

// ---- helpers ----------------------------------------------------------

function findTile(system, bodyUid, tileId) {
  const walk = (bodies) => {
    for (const b of bodies || []) {
      if (b.uid === bodyUid) return (b.tiles || []).find((t) => t.id === tileId);
      const sub = walk(b.bodies);
      if (sub) return sub;
    }
    return null;
  };
  return walk(system.bodies);
}

async function serverQueue(page) {
  const sys = await serverSystem(page, homeSystemId);
  return {
    system: sys,
    production: sys.production.value,
    items: sys.queue.queue.map((q) => ({
      id: q.id, key: q.prod_key, total: q.total_prod, remaining: q.remaining_prod, body: q.target_id, tile: q.tile_id,
    })),
  };
}

const ids = (items) => items.map((i) => i.id);

// Order of the cards the player sees in the queue panel.
function domOrder(page) {
  return page.$$eval('.system-production-queue-item', (els) => els.map((el) => Number(el.dataset.productionId)));
}

function storeOrder(page) {
  return page.evaluate(() => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    return s.queue.queue.map((q) => q.id);
  });
}

async function waitStoreOrder(page, want) {
  await page.waitForFunction((w) => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    return s && JSON.stringify(s.queue.queue.map((q) => q.id)) === JSON.stringify(w);
  }, want, { timeout: 10000 });
}

async function openQueuePanel(page) {
  if (await page.locator('.system-production-queue').count() === 0) {
    await page.locator('.production-box .round-icon').click({ timeout: 10000 });
  }
  await expect(page.locator('.system-production-queue-item').first()).toBeVisible();
}

function card(page, id) {
  return page.locator(`.system-production-queue-item[data-production-id="${id}"]`);
}

// Real HTML5 drag with the mouse: grab `id`'s card and drop it on the top
// (before) or bottom (after) edge of `targetId`'s card. `midDrag` runs
// while the card is held over the drop spot, before releasing.
async function dragCard(page, id, targetId, where = 'before', midDrag = null) {
  const from = await card(page, id).boundingBox();
  const to = await card(page, targetId).boundingBox();
  const y = where === 'before' ? to.y + to.height * 0.2 : to.y + to.height * 0.8;

  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  // two moves: the first starts the native drag, the second hits the target
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2 + 5);
  await page.mouse.move(to.x + to.width / 2, y, { steps: 8 });
  if (midDrag) await midDrag();
  await page.mouse.up();
}

async function readHint(page) {
  // The drop indicator proves dragover has been processed and rendered
  // for the hovered spot; the hint reflects that same preview.
  await page.locator('.system-production-queue-item.drop-before, .system-production-queue-item.drop-after')
    .first().waitFor({ timeout: 5000 });
  const hint = page.locator('.system-production-queue-hint');
  return {
    text: await hint.innerText(),
    warning: await hint.evaluate((el) => el.classList.contains('warning')),
  };
}

async function setSpeed(page, mult) {
  const res = await setSpeedCheat(page, mult);
  expect(res.ok, `set_speed ${mult} failed: ${res.error}`).toBe(true);
  speed = mult;
}

// Production per real millisecond, measured on the server (independent of
// client clock factors and the speed cheat's bookkeeping).
async function measureRate(page, windowMs = 3000) {
  const a = await serverQueue(page);
  const t0 = Date.now();
  await page.waitForTimeout(windowMs);
  const b = await serverQueue(page);
  const dt = Date.now() - t0;
  const head = a.items[0];
  const headLater = b.items.find((i) => i.id === head.id);
  expect(headLater && ids(b.items)[0] === head.id, 'head changed while measuring the production rate').toBeTruthy();
  const rate = (head.remaining - headLater.remaining) / dt;
  expect(rate, 'the home system produces nothing — cannot test construction timing').toBeGreaterThan(0);
  return rate;
}

// Pick the speed multiplier that makes `production` take closest to
// `targetMs` of real time, given the rate measured at the current speed.
function speedFor(production, ratePerMs, targetMs) {
  const basePerMs = ratePerMs / speed;
  return SPEEDS.reduce((best, s) => {
    const ms = production / (basePerMs * s);
    const bestMs = production / (basePerMs * best);
    return Math.abs(Math.log(ms / targetMs)) < Math.abs(Math.log(bestMs / targetMs)) ? s : best;
  }, SPEEDS[0]);
}

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 500000, technology: 20000, ideology: 5000 },
    // mobile_ui explicitly on: the fixture makes this list the account's
    // exact feature set, and the mobile step needs the phone layout.
    ['slim_sync', 'mobile_ui'],
  );
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});

test('construction queue: drag to reorder, nothing completes early', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);

  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);
  // Slow the world down while the queue is being set up.
  await setSpeed(page, 0.25);
  await openSystem(page, homeSystemId);

  let spots = [];

  await test.step('queue four constructions', async () => {
    for (let i = 0; i < 8 && spots.length < 4; i++) {
      // prefer a mix of buildings, so costs differ
      const spot = await orderOneBuild(page, homeSystemId, spots.map((sp) => sp.key));
      if (!spot) break;
      spots.push(spot);
    }
    expect(spots.length, 'could not queue enough constructions').toBeGreaterThanOrEqual(3);

    const q = await serverQueue(page);
    expect(q.items.length).toBe(spots.length);
    // ids are unique from the start
    expect(new Set(ids(q.items)).size).toBe(q.items.length);
    const costs = new Set(q.items.map((i) => i.total));
    expect(costs.size, `need different construction costs, got ${JSON.stringify(q.items)}`).toBeGreaterThan(1);
  });

  await test.step('stale or malformed orders are refused and change nothing', async () => {
    const before = await serverQueue(page);
    const live = ids(before.items);
    const other = await page.evaluate((home) => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const owned = new Set((st.player.stellar_systems || []).map((s) => s.id));
      const sys = (st.galaxy.stellar_systems || []).find((s) => !owned.has(s.id) && s.id !== home);
      return sys && sys.id;
    }, homeSystemId);

    const cases = [
      [{ system_id: homeSystemId, production_ids: live.slice(1) }, 'queue_changed'], // missing one
      [{ system_id: homeSystemId, production_ids: [...live, Math.max(...live) + 100] }, 'queue_changed'], // extra
      [{ system_id: homeSystemId, production_ids: [live[0], ...live.slice(0, -1)] }, 'queue_changed'], // duplicate
      [{ system_id: homeSystemId, production_ids: live.map((id) => id + 1000) }, 'queue_changed'], // unknown
      [{ system_id: homeSystemId, production_ids: live.map(String) }, 'invalid_payload'],
      [{ system_id: homeSystemId, production_ids: [] }, 'invalid_payload'],
      [{ system_id: homeSystemId, production_ids: 'all' }, 'invalid_payload'],
      [{ system_id: String(homeSystemId), production_ids: live }, 'invalid_payload'],
      [{ system_id: other, production_ids: live }, 'system_not_found'], // not ours
    ];
    for (const [payload, reason] of cases) {
      const res = await playerPush(page, 'reorder_production', payload);
      expect(res.ok, `accepted ${JSON.stringify(payload)}`).toBe(false);
      expect(res.error, JSON.stringify(payload)).toBe(reason);
    }

    const after = await serverQueue(page);
    expect(ids(after.items)).toEqual(live);
    // the player agent survived every refusal (a crash = genesis reset)
    const alive = await serverPlayer(page);
    expect(alive.stellar_systems.map((s) => s.id)).toContain(homeSystemId);
  });

  await test.step('dragging a card reorders the queue: UI → server → UI', async () => {
    await openQueuePanel(page);
    const before = await serverQueue(page);
    const live = ids(before.items);
    expect(await domOrder(page)).toEqual(live);
    await expect(page.locator('.system-production-queue-item[draggable="true"]')).toHaveCount(live.length);

    // last → first
    const last = live[live.length - 1];
    let hint = null;
    await dragCard(page, last, live[0], 'before', async () => {
      hint = await readHint(page);
    });
    const want = [last, ...live.slice(0, -1)];

    await waitStoreOrder(page, want);
    expect(ids((await serverQueue(page)).items)).toEqual(want);
    await expect.poll(() => domOrder(page)).toEqual(want);
    // displacing the head (always mid-build while the system produces)
    // warned that it would lose its progress
    expect(hint.warning, hint.text).toBe(true);
  });

  await test.step('reordering behind the head keeps its progress', async () => {
    const before = await serverQueue(page);
    const live = ids(before.items);
    // wait for measurable head progress
    await expect.poll(async () => {
      const q = await serverQueue(page);
      return q.items[0].total - q.items[0].remaining;
    }, { timeout: 30000 }).toBeGreaterThan(0);
    const mid = await serverQueue(page);
    const headProgress = mid.items[0].total - mid.items[0].remaining;

    // move the second card to the end: head unchanged, no warning
    let hint = null;
    await dragCard(page, live[1], live[live.length - 1], 'after', async () => {
      hint = await readHint(page);
    });
    const want = [live[0], ...live.slice(2), live[1]];
    await waitStoreOrder(page, want);

    const after = await serverQueue(page);
    expect(ids(after.items)).toEqual(want);
    expect(after.items[0].total - after.items[0].remaining).toBeGreaterThanOrEqual(headProgress);
    expect(hint.warning, hint.text).toBe(false);
    // every non-head item is at full cost
    after.items.slice(1).forEach((i) => expect(i.remaining).toBe(i.total));
  });

  await test.step('the order survives a reload', async () => {
    const want = ids((await serverQueue(page)).items);
    await page.reload();
    await waitConnected(page);
    await instrument(page);
    await openSystem(page, homeSystemId);
    expect(await storeOrder(page)).toEqual(want);
    await openQueuePanel(page);
    expect(await domOrder(page)).toEqual(want);
  });

  await test.step('mobile: no drag affordance', async () => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.waitForFunction(() => document.body.classList.contains('is-mobile-ui'));
    await expect(page.locator('.system-production-queue-item[draggable="true"]')).toHaveCount(0);
    await expect(page.locator('.system-production-queue-hint')).toHaveCount(0);
    await page.setViewportSize(DESKTOP);
    await page.waitForFunction(() => !document.body.classList.contains('is-mobile-ui'));
    await openSystem(page, homeSystemId);
    await openQueuePanel(page);
  });

  await test.step('dragging ahead of a nearly finished head completes nothing early', async () => {
    // Make the cheapest item the head and the most expensive the one we
    // drag in front of it.
    let q = await serverQueue(page);
    const cheap = q.items.reduce((a, b) => (b.total < a.total ? b : a));
    const pricey = q.items.filter((i) => i.id !== cheap.id).reduce((a, b) => (b.total > a.total ? b : a));
    expect(pricey.total).toBeGreaterThan(cheap.total);
    if (q.items[0].id !== cheap.id) {
      const order = [cheap.id, ...ids(q.items).filter((id) => id !== cheap.id)];
      const res = await playerPush(page, 'reorder_production', { system_id: homeSystemId, production_ids: order });
      expect(res.ok, res.error).toBe(true);
      await waitStoreOrder(page, order);
    }

    // Time it so the cheap head takes ~24 s of real time.
    const rate = await measureRate(page);
    await setSpeed(page, speedFor(cheap.total, rate, 24000));
    const fastRate = await measureRate(page, 2000);
    const cheapMs = cheap.total / fastRate;
    expect(pricey.total / fastRate, 'expensive item would finish during the observation window')
      .toBeGreaterThan(cheapMs * 0.6);

    // Let the cheap head get ~70% built.
    const deadline = Date.now() + cheapMs * 2;
    for (;;) {
      const h = (await serverQueue(page)).items[0];
      expect(h.id, 'the cheap head finished before the drag').toBe(cheap.id);
      if (1 - h.remaining / h.total > 0.7) break;
      expect(Date.now(), 'the cheap head never reached 70%').toBeLessThan(deadline);
      await page.waitForTimeout(250);
    }

    q = await serverQueue(page);
    const cheapLeft = q.items[0].remaining;
    const cheapWouldFinishAt = Date.now() + cheapLeft / fastRate;
    expect(cheapWouldFinishAt - Date.now(), 'not enough margin to drag before completion').toBeGreaterThan(2000);

    let hint = null;
    await dragCard(page, pricey.id, cheap.id, 'before', async () => {
      hint = await readHint(page);
    });
    expect(hint.warning, hint.text).toBe(true);

    const want = [pricey.id, ...ids(q.items).filter((id) => id !== pricey.id)];
    await waitStoreOrder(page, want);

    const after = await serverQueue(page);
    expect(ids(after.items)).toEqual(want);
    const cheapAfter = after.items.find((i) => i.id === cheap.id);
    const priceyAfter = after.items[0];
    // the cheap item's progress is gone, not transferred
    expect(cheapAfter.remaining).toBe(cheapAfter.total);
    expect(priceyAfter.total - priceyAfter.remaining).toBeLessThan(cheap.total * 0.3);

    // Wait until well past the moment the cheap item would have finished.
    const dropAt = Date.now();
    await page.waitForTimeout(Math.max(0, cheapWouldFinishAt - Date.now()) + 4000);

    const later = await serverQueue(page);
    const elapsed = Date.now() - dropAt;
    expect(ids(later.items)).toEqual(want);
    const cheapLater = later.items.find((i) => i.id === cheap.id);
    expect(cheapLater.remaining).toBe(cheapLater.total);
    const cheapTile = findTile(later.system, cheap.body, cheap.tile);
    expect(cheapTile.building_status).not.toBe('built');
    expect(cheapTile.construction_status).not.toBe('none');
    // and the expensive head progressed at the normal rate, from scratch
    const priceyLater = later.items[0];
    const expected = fastRate * elapsed;
    expect(priceyLater.total - priceyLater.remaining).toBeGreaterThan(expected * 0.6);
    expect(priceyLater.total - priceyLater.remaining).toBeLessThan(priceyAfter.total - priceyAfter.remaining + expected * 1.4);

    await setSpeed(page, 0.25);
  });

  await test.step('new orders and cancels stay unique after reorders', async () => {
    const before = await serverQueue(page);
    const spot = await orderOneBuild(page, homeSystemId);
    expect(spot, 'no further build order accepted').toBeTruthy();

    const q = await serverQueue(page);
    const added = q.items[q.items.length - 1];
    expect(new Set(ids(q.items)).size).toBe(q.items.length);
    expect(added.id).toBe(Math.max(...ids(before.items)) + 1);

    // cancel a reordered item from the middle via the card's × button
    const victim = q.items[1];
    const credit0 = (await serverPlayer(page)).credit.value;
    await card(page, victim.id).hover();
    await card(page, victim.id).locator('.card-header-toast svg').click();
    const want = ids(q.items).filter((id) => id !== victim.id);
    await waitStoreOrder(page, want);

    const after = await serverQueue(page);
    expect(ids(after.items)).toEqual(want);
    expect((await serverPlayer(page)).credit.value).toBeGreaterThan(credit0);
  });

  await test.step('constructions complete in the new order', async () => {
    const q = await serverQueue(page);
    const expectedOrder = ids(q.items);
    const totalLeft = q.items.reduce((acc, i) => acc + i.remaining, 0);

    const rate = await measureRate(page, 2000);
    await setSpeed(page, speedFor(totalLeft, rate, 60000));

    const completed = [];
    const seen = new Set();
    const violations = [];
    await expect.poll(async () => {
      const s = await serverQueue(page);
      // at every observation the live queue is a suffix of the new order
      const live = ids(s.items);
      if (JSON.stringify(live) !== JSON.stringify(expectedOrder.slice(expectedOrder.length - live.length))) {
        violations.push(live);
        return -1;
      }
      q.items.forEach((item) => {
        if (seen.has(item.id)) return;
        const t = findTile(s.system, item.body, item.tile);
        if (t && t.building_status === 'built') { seen.add(item.id); completed.push(item.id); }
      });
      return s.items.length;
    }, { timeout: 5 * 60 * 1000, intervals: [300] }).toBeLessThanOrEqual(0);

    expect(violations, `queue left the new order: ${JSON.stringify(violations)}`).toEqual([]);
    expect(completed).toEqual(expectedOrder);
    const c = await counters(page);
    expect(c.errors).toEqual([]);
  });
});
