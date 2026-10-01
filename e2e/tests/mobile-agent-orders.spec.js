// Agent orders on a phone (the mobile UI, touch input):
//   - the selected agent's card shows the orders as the editable plan,
//     beside the card, with the bulk-order buttons above it: a tap selects
//     a stop, the toolbar moves or removes it; an action of the selected
//     stop and "clear all" each ask for a second tap;
//   - multi-move: the card closes, a banner says what a tap now does,
//     every tap on a system queues a move there (it never opens the
//     system or drops the selection), a double-tap ends it — and so does
//     bringing the card back up;
//   - long-press on a system: the action wheel opens WHILE the finger is
//     down; sliding to an order and lifting picks it (the map does not
//     pan under the finger), lifting in place leaves the wheel up for a
//     tap, and a tap elsewhere closes it without doing anything else.
// Touches are real ones (CDP Input.dispatchTouchEvent), so the pointer
// events the map and the wheel listen to are the browser's own.
// Server truth: get_character (the queue the engine will execute).
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

let api;
let instanceId;
let homeSystemId;

// ---- helpers ----------------------------------------------------------

async function serverQueue(page, characterId) {
  const res = await playerPush(page, 'get_character', { character_id: characterId });
  if (!res.ok) throw new Error(`get_character: ${res.error}`);
  return res.data.character.actions.queue.map((a) => ({
    type: a.type, source: a.data.source, target: a.data.target, stop: !!a.data.stop, uid: a.uid,
  }));
}

// The queue as stops: marked jumps and actions (the route in between left out).
const describeStops = (q) => q.filter((a) => a.type !== 'jump' || a.stop)
  .map((a) => (a.type === 'jump' ? `*${a.target}` : `${a.type}@${a.target}`));

function planRows(page) {
  return page.$$eval('.agent-plan .agent-plan-row', (els) => els.map((el) => ({
    kind: el.dataset.planRow,
    system: Number(el.dataset.systemId),
    actions: [...el.querySelectorAll('.agent-plan-action')].map((a) => a.dataset.actionType),
    selected: el.classList.contains('is-selected'),
    doomed: el.classList.contains('is-doomed'),
  })));
}

// The panel ignores touches while an edit is on its way; it is settled
// once the client's copy of the queue shows the edit.
async function planSettled(page, systems) {
  await expect.poll(async () => (await planRows(page)).map((r) => r.system)).toEqual(systems);
  await expect(page.locator('.agent-plan')).not.toHaveClass(/is-pending/);
}

const stopRow = (page, systemId) => page.locator(`.agent-plan .agent-plan-row[data-plan-row="stop"][data-system-id="${systemId}"]`);

const game = (page, key) => page.evaluate((k) => {
  const st = document.querySelector('#app').__vue__.$store.state.game;
  return ({ multiMove: st.multiMove, selected: !!st.selectedCharacter, system: !!st.selectedSystem })[k];
}, key);

const box = (page, selector) => page.evaluate((sel) => {
  const el = document.querySelector(sel);
  if (!el) return null;
  const b = el.getBoundingClientRect();
  return { left: b.left, top: b.top, right: b.right, bottom: b.bottom };
}, selector);

const camera = (page) => page.evaluate(() => {
  const c = window.__rcMap.camera.position;
  return [c.x, c.y, c.z].map((n) => Math.round(n * 1000) / 1000);
});

// Camera moves are 600 ms tweens (centering on a system; a tap on the
// agent bubble centers on the agent): screen positions are only good
// once it has stopped.
async function cameraStill(page) {
  await page.waitForTimeout(700);
  let last = await camera(page);
  await expect.poll(async () => {
    const now = await camera(page);
    const still = JSON.stringify(now) === JSON.stringify(last);
    last = now;
    return still;
  }, { intervals: [250] }).toBe(true);
}

async function centerOn(page, systemId) {
  await page.evaluate((id) => { document.querySelector('#app').__vue__.$root.$emit('map:centerToSystem', id); }, systemId);
  await cameraStill(page);
}

// Systems on screen, clear of the bars, the agent bubble and the map
// tools, at their screen position — minus `skip` (ids).
function systemsInView(page, skip = []) {
  return page.evaluate((ids) => {
    const m = window.__rcMap;
    return m.data.systems.filter((s) => !ids.includes(s.id)).map((s) => {
      const v = m.camera.position.clone().set(s.position.x, s.position.y, 0).project(m.camera);
      return { id: s.id, x: ((v.x + 1) / 2) * window.innerWidth, y: ((1 - v.y) / 2) * window.innerHeight };
    }).filter((s) => s.x > 60 && s.x < 330 && s.y > 150 && s.y < 580);
  }, skip);
}

// At least `n` of them: random galaxies can be sparse around the agent,
// so zoom out a step at a time until there are (systems stay tappable up
// to z 200, where the map switches to its far view).
async function enoughSystemsInView(page, n, skip = []) {
  for (let z = 70; z <= 190; z += 30) {
    await page.evaluate((zz) => {
      const m = window.__rcMap;
      m.setCameraPosition(m.camera.position.x, m.camera.position.y, zz);
      m.onZ(zz);
    }, z);
    await page.waitForTimeout(300);
    const found = await systemsInView(page, skip);
    if (found.length >= n) return found;
  }
  throw new Error(`fewer than ${n} systems in view, even zoomed out`);
}

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);
  const fixture = await api.createAgentFixture(PLAYER.email, { credit: 100000, technology: 1000, ideology: 1000 });
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('phone: plan beside the card, multi-move, long-press action wheel', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);

  const cdp = await context.newCDPSession(page);
  const touch = (type, points) => cdp.send('Input.dispatchTouchEvent', {
    type, touchPoints: points.map(([x, y]) => ({ x, y, id: 1 })),
  });
  const tapAt = async (x, y) => {
    await touch('touchStart', [[x, y]]);
    await page.waitForTimeout(50);
    await touch('touchEnd', []);
  };
  const hold = async (x, y, ms) => {
    await touch('touchStart', [[x, y]]);
    await page.waitForTimeout(ms);
  };

  // slowest speed: the head jump stays in flight for the whole spec
  const speed = await setSpeedCheat(page, 0.25);
  expect(speed.ok, speed.error).toBe(true);

  const admiral = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return st.player.characters.find((c) => c.type === 'admiral').id;
  });

  // bombard/pillage need a fleet: one ship via the creator fleet cheat
  const armed = await page.evaluate((cid) => new Promise((resolve) => {
    const app = document.querySelector('#app').__vue__;
    const ship = app.$store.state.game.data.ship[0].key;
    app.$socket.joinCheat().push('fleet_add_ship', { character_id: cid, ship_key: ship, level: 1 })
      .receive('ok', () => resolve({ ok: true }))
      .receive('error', (e) => resolve({ ok: false, error: e && e.reason }));
  }), admiral);
  expect(armed.ok, `fleet_add_ship: ${armed.error}`).toBe(true);

  // O → A (the running head), then stops B, C (bombard + pillage), D, E:
  // a walk along lanes, one hop per stop
  const walk = await page.evaluate((home) => {
    const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
    const nb = (id) => edges.filter((e) => e.s1.id === id || e.s2.id === id).map((e) => (e.s1.id === id ? e.s2.id : e.s1.id));
    const path = [home];
    while (path.length < 6) {
      const next = nb(path[path.length - 1]).find((x) => !path.includes(x));
      if (next === undefined) break;
      path.push(next);
    }
    return path;
  }, homeSystemId);
  expect(walk.length, 'no 5-hop walk from home').toBe(6);
  const [O, A, B, C, D, E] = walk;
  const jump = (source, target) => ({ type: 'jump', data: { source, target, stop: true } });
  const placed = await playerPush(page, 'add_character_actions', {
    character_id: admiral,
    actions: [jump(O, A), jump(A, B), jump(B, C), { type: 'raid', data: { target: C } }, { type: 'loot', data: { target: C } }, jump(C, D), jump(D, E)],
  });
  expect(placed.ok, placed.error).toBe(true);

  await page.evaluate((id) => {
    const app = document.querySelector('#app').__vue__;
    return app.$store.dispatch('game/selectCharacter', { vm: app, id });
  }, admiral);
  const bubble = page.locator('.mobile-agent-bubble');
  await expect(bubble).toBeVisible();
  const sheet = page.locator('.mobile-agent-sheet');
  const openCard = async () => {
    await bubble.tap();
    await bubble.tap();
    await expect(sheet).toBeVisible();
  };

  await test.step('the card: bulk orders above, the plan beside the agent, the fleet under both', async () => {
    await openCard();
    await expect(page.locator('.adp-plan.agent-plan.is-compact')).toBeVisible();
    // the icon strip the plan replaces is gone
    await expect(page.locator('.mobile-agent-sheet .adp-queue')).toHaveCount(0);

    const top = await box(page, '.mobile-agent-sheet .adp-top');
    const card = await box(page, '.mobile-agent-sheet .adp-card');
    const plan = await box(page, '.mobile-agent-sheet .adp-plan');
    const aside = await box(page, '.mobile-agent-sheet .adp-aside');
    expect(top.bottom).toBeLessThanOrEqual(card.top);
    expect(plan.left).toBeGreaterThanOrEqual(card.right);
    expect(plan.right).toBeLessThanOrEqual(390);
    expect(Math.abs(plan.top - card.top)).toBeLessThanOrEqual(2);
    // a long plan scrolls within the card's height: the fleet stays put under both
    expect(plan.bottom).toBeLessThanOrEqual(card.bottom + 1);
    expect(aside.top).toBeGreaterThanOrEqual(card.bottom);
    await expect(page.locator('[data-bulk="multi-move"]')).toBeVisible();

    await expect.poll(() => planRows(page)).toEqual([
      expect.objectContaining({ kind: 'head', system: A }),
      expect.objectContaining({ kind: 'stop', system: B, actions: [] }),
      expect.objectContaining({ kind: 'stop', system: C, actions: ['raid', 'loot'] }),
      expect.objectContaining({ kind: 'stop', system: D, actions: [] }),
      expect.objectContaining({ kind: 'stop', system: E, actions: [] }),
    ]);
    // no hover ×s on a phone; the toolbar waits for a selection
    await expect(page.locator('.agent-plan .agent-plan-remove')).toHaveCount(0);
    await expect(page.locator('[data-plan-toolbar] .agent-plan-hint')).toBeVisible();
    // every row fits the panel
    const overflow = await page.$$eval('.agent-plan .agent-plan-row', (els) => els.filter((el) => el.scrollWidth > el.clientWidth + 1).length);
    expect(overflow).toBe(0);
  });

  await test.step('a tap selects a stop; the toolbar moves it up, and it stays selected', async () => {
    await stopRow(page, C).locator('.agent-plan-number').tap();
    await expect(stopRow(page, C)).toHaveClass(/is-selected/);
    await expect(page.locator('[data-plan-toolbar] .agent-plan-toolbar-name')).toBeVisible();
    // nothing happened yet
    expect(describeStops(await serverQueue(page, admiral))).toEqual([`*${A}`, `*${B}`, `*${C}`, `raid@${C}`, `loot@${C}`, `*${D}`, `*${E}`]);

    await page.locator('[data-plan-tool="up"]').tap();
    await expect.poll(async () => describeStops(await serverQueue(page, admiral)))
      .toEqual([`*${A}`, `*${C}`, `raid@${C}`, `loot@${C}`, `*${B}`, `*${D}`, `*${E}`]);
    await planSettled(page, [A, C, B, D, E]);
    await expect(stopRow(page, C)).toHaveClass(/is-selected/);
    // first of the editable stops: it cannot go further up
    await expect(page.locator('[data-plan-tool="up"]')).toBeDisabled();
    await expect(page.locator('[data-plan-tool="down"]')).toBeEnabled();
  });

  await test.step('an action of the selected stop: one tap marks it, a second cancels it', async () => {
    const stops = [`*${A}`, `*${C}`, `raid@${C}`, `loot@${C}`, `*${B}`, `*${D}`, `*${E}`];
    const raid = stopRow(page, C).locator('.agent-plan-action[data-action-type="raid"]');
    const loot = stopRow(page, C).locator('.agent-plan-action[data-action-type="loot"]');

    // C is selected: the first tap on its bombard only marks it
    await raid.tap();
    await expect(raid).toHaveClass(/is-doomed/);
    await expect(loot).not.toHaveClass(/is-doomed/);
    await page.waitForTimeout(500);
    expect(describeStops(await serverQueue(page, admiral))).toEqual(stops);

    await raid.tap();
    await expect.poll(async () => describeStops(await serverQueue(page, admiral)))
      .toEqual(stops.filter((x) => x !== `raid@${C}`));
    await expect.poll(async () => (await planRows(page)).find((r) => r.system === C).actions).toEqual(['loot']);
    await planSettled(page, [A, C, B, D, E]);
    // the stop was named after its bombard: it is still the selected one
    await expect(stopRow(page, C)).toHaveClass(/is-selected/);

    // deselect (a tap on the row), then tap the pillage: on a stop that
    // is not selected, a tap on an action selects the stop and no more
    await stopRow(page, C).locator('.agent-plan-number').tap();
    await expect(stopRow(page, C)).not.toHaveClass(/is-selected/);
    await loot.tap();
    await expect(stopRow(page, C)).toHaveClass(/is-selected/);
    await expect(loot).not.toHaveClass(/is-doomed/);
    await page.waitForTimeout(500);
    expect(describeStops(await serverQueue(page, admiral))).toEqual(stops.filter((x) => x !== `raid@${C}`));
  });

  await test.step('the toolbar removes the selected stop', async () => {
    await stopRow(page, D).locator('.agent-plan-number').tap();
    await expect(stopRow(page, D)).toHaveClass(/is-selected/);
    await page.locator('[data-plan-tool="remove"]').tap();
    await expect.poll(async () => describeStops(await serverQueue(page, admiral)))
      .toEqual([`*${A}`, `*${C}`, `loot@${C}`, `*${B}`, `*${E}`]);
    await planSettled(page, [A, C, B, E]);
    await expect(page.locator('[data-plan-toolbar] .agent-plan-hint')).toBeVisible();
    // never a notification box for an edit
    expect(await page.evaluate(() => document.querySelector('#app').__vue__.$store.state.game.boxNotifications.length)).toBe(0);
    await page.evaluate(() => document.querySelectorAll('.toasted').forEach((el) => el.remove()));
  });

  await test.step('"clear all" marks every stop and waits for a second tap', async () => {
    const clear = page.locator('.agent-plan [data-plan-clear]');
    const before = describeStops(await serverQueue(page, admiral));
    await clear.tap();
    await expect(clear).toHaveClass(/is-armed/);
    expect((await planRows(page)).filter((r) => r.kind === 'stop').every((r) => r.doomed)).toBe(true);
    await page.waitForTimeout(500);
    expect(describeStops(await serverQueue(page, admiral))).toEqual(before);

    await clear.tap();
    await expect.poll(async () => describeStops(await serverQueue(page, admiral))).toEqual([`*${A}`]);
    await expect.poll(async () => (await planRows(page)).map((r) => r.kind)).toEqual(['head']);
    await expect(clear).toHaveCount(0);
  });

  let queued;
  await test.step('multi-move: the card closes, a banner says so, taps on systems queue moves', async () => {
    await page.locator('[data-bulk="multi-move"]').tap();
    await expect(sheet).toHaveCount(0);
    expect(await game(page, 'multiMove')).toBe(true);
    const banner = page.locator('[data-multi-move-banner]');
    await expect(banner).toBeVisible();
    await expect(banner).toContainText('Double-tap to stop');
    // bottom middle, clear of the agent bubble and the bars
    const b = await box(page, '[data-multi-move-banner]');
    const bub = await box(page, '.mobile-agent-bubble');
    expect(Math.abs(((b.left + b.right) / 2) - 195)).toBeLessThanOrEqual(2);
    expect(b.top).toBeGreaterThan(844 / 2);
    expect(b.bottom).toBeLessThanOrEqual(bub.top);

    // three systems in view, one after the other — faster than a person
    // would, and without waiting for the client to hear back
    await centerOn(page, A);
    const picks = (await enoughSystemsInView(page, 3, [O, A])).slice(0, 3);
    for (const s of picks) {
      await tapAt(s.x, s.y);
      await page.waitForTimeout(400);
    }
    queued = picks.map((s) => s.id);
    await expect.poll(async () => describeStops(await serverQueue(page, admiral)))
      .toEqual([`*${A}`, ...queued.map((id) => `*${id}`)]);
    // each leg starts where the previous one ends
    const q = await serverQueue(page, admiral);
    q.filter((a) => a.type === 'jump').reduce((pos, a) => {
      expect(a.source).toBe(pos);
      return a.target;
    }, O);
    // a tap opened no system and kept the agent selected
    expect(await game(page, 'system')).toBe(false);
    expect(await game(page, 'selected')).toBe(true);
    // the last tapped system pulses for a moment
    expect(await page.evaluate(() => window.__rcMap.scene.getObjectByName('queue-destination-pulse').userData.systemId)).toBe(queued[2]);
  });

  await test.step('multi-move: a tap on nothing changes nothing; a double-tap ends it', async () => {
    const before = describeStops(await serverQueue(page, admiral));
    await page.waitForTimeout(500);
    await tapAt(20, 330);
    await page.waitForTimeout(600);
    expect(await game(page, 'multiMove')).toBe(true);
    expect(await game(page, 'selected')).toBe(true);

    await tapAt(20, 330);
    await page.waitForTimeout(120);
    await tapAt(20, 330);
    await expect.poll(() => game(page, 'multiMove')).toBe(false);
    await expect(page.locator('[data-multi-move-banner]')).toHaveCount(0);
    expect(await game(page, 'selected')).toBe(true);
    expect(describeStops(await serverQueue(page, admiral))).toEqual(before);
  });

  await test.step('multi-move: bringing the card back up ends it too', async () => {
    await page.waitForTimeout(400);
    await openCard();
    await page.locator('[data-bulk="multi-move"]').tap();
    await expect(page.locator('[data-multi-move-banner]')).toBeVisible();
    await openCard();
    expect(await game(page, 'multiMove')).toBe(false);
    await expect(page.locator('[data-multi-move-banner]')).toHaveCount(0);
    // the plan shows what the taps queued
    await expect.poll(async () => (await planRows(page)).map((r) => r.system)).toEqual([A, ...queued]);
    await page.locator('.mas-close').tap();
    await expect(sheet).toHaveCount(0);
  });

  await test.step('long-press: the wheel opens under the finger; slide to an order and lift', async () => {
    await cameraStill(page);
    const tail = queued[queued.length - 1];
    const [target, other] = await enoughSystemsInView(page, 2, [O, A, tail]);
    // (the wheel's own box is a zero-size anchor: its items are what shows)
    const wheel = page.locator('.map-action-radial');
    const before = await serverQueue(page, admiral);

    await hold(target.x, target.y, 250);
    // not yet: a quick tap must stay a tap
    await expect(wheel).toHaveCount(0);
    await page.waitForTimeout(450);
    // the finger is still down, and the orders are already there
    await expect(wheel).toHaveCount(1);
    await expect(wheel).toHaveClass(/is-held/);
    const move = page.locator('.map-action-radial-item[data-action="jump"]');
    await expect(move).toBeVisible();

    const cam = await camera(page);
    const icon = await box(page, '.map-action-radial-item[data-action="jump"] .radial-icon');
    const to = { x: (icon.left + icon.right) / 2, y: (icon.top + icon.bottom) / 2 };
    for (let i = 1; i <= 6; i += 1) {
      await touch('touchMove', [[target.x + ((to.x - target.x) * i) / 6, target.y + ((to.y - target.y) * i) / 6]]);
      await page.waitForTimeout(30);
    }
    await expect(move).toHaveClass(/is-hot/);
    // the slide belongs to the wheel: the map did not pan under it
    expect(await camera(page)).toEqual(cam);

    await touch('touchEnd', []);
    await expect(wheel).toHaveCount(0);
    await expect.poll(async () => (await serverQueue(page, admiral)).length).toBeGreaterThan(before.length);
    const after = await serverQueue(page, admiral);
    expect(after[after.length - 1]).toEqual(expect.objectContaining({ type: 'jump', target: target.id, stop: true }));
    expect(await game(page, 'system')).toBe(false);

    await test.step('lifting in place leaves the wheel up; a tap elsewhere only closes it', async () => {
      await hold(other.x, other.y, 700);
      await expect(wheel).toHaveCount(1);
      await touch('touchEnd', []);
      await page.waitForTimeout(300);
      await expect(wheel).toHaveCount(1);
      await expect(wheel).not.toHaveClass(/is-held/);
      expect(await game(page, 'system')).toBe(false);

      await tapAt(20, 330);
      await expect(wheel).toHaveCount(0);
      await page.waitForTimeout(400);
      // that tap was "never mind": the agent is still selected, no system opened
      expect(await game(page, 'selected')).toBe(true);
      expect(await game(page, 'system')).toBe(false);
      expect((await serverQueue(page, admiral)).length).toBe(after.length);
    });

    await test.step('…or the order is tapped after lifting', async () => {
      await hold(other.x, other.y, 700);
      await touch('touchEnd', []);
      await expect(wheel).toHaveCount(1);
      await move.tap();
      await expect(wheel).toHaveCount(0);
      await expect.poll(async () => (await serverQueue(page, admiral)).slice(-1)[0].target).toBe(other.id);
    });

    await test.step('a short tap on a system still opens it', async () => {
      await page.waitForTimeout(400);
      await tapAt(other.x, other.y);
      await expect.poll(() => game(page, 'system')).toBe(true);
      await expect(wheel).toHaveCount(0);
    });
  });

  const errors = await page.evaluate(() => window.__e2e.errors);
  expect(errors).toEqual([]);
});
