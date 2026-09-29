// Agent plan editing (desktop): the queue shown as STOPS — systems the
// player chose, with their actions — where jumps in between are route.
//
// The scenario is the one from the feature request:
//   Move A, Move B, Move C, Bombard C, Pillage C, Move D
// placed through the real map order path (map:addAction, as the radial
// menu / right-click do), then edited from the selection panel:
//   - every row says when the agent will be done there (hover: how long
//     from now), "—" from the first action whose duration isn't known yet;
//   - hovering a row pulses its destination on the map: a ring from the
//     edge of the system's icon, faction color (soft gray when unowned);
//   - hovering a stop's × marks everything that would go with it;
//   - removing stop B re-routes A → C (through B again if it's on the way:
//     then the notification explains B is passed through, not stopped at);
//   - cancelling one action keeps the stop and its other action;
//   - dragging D above C re-routes both legs, actions follow their stop;
//   - removing C takes its actions with it;
//   - a stale edit is refused; a reload rebuilds the same stops.
// Server truth: get_character (the queue the engine will execute).
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

test.use({ viewport: { width: 1920, height: 1080 } });

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

const describeQueue = (q) => q.map((a) => (a.type === 'jump' ? `${a.source}>${a.target}${a.stop ? '*' : ''}` : `${a.type}@${a.target}`));

// every jump starts where the previous entry left the agent
function assertChained(q, origin) {
  let pos = origin;
  q.forEach((a) => {
    if (a.type === 'jump') {
      expect(a.source, `broken chain in ${JSON.stringify(describeQueue(q))}`).toBe(pos);
      pos = a.target;
    } else {
      expect(a.target, `action away from the agent in ${JSON.stringify(describeQueue(q))}`).toBe(pos);
    }
  });
}

// The rows the player sees in the plan panel.
function planRows(page) {
  return page.$$eval('.agent-plan .agent-plan-row', (els) => els.map((el) => ({
    kind: el.dataset.planRow,
    system: Number(el.dataset.systemId),
    key: el.dataset.stopKey || null,
    actions: [...el.querySelectorAll('.agent-plan-action')].map((a) => a.dataset.actionType),
  })));
}

const row = (page, systemId) => page.locator(`.agent-plan .agent-plan-row[data-plan-row="stop"][data-system-id="${systemId}"], .agent-plan .agent-plan-row[data-plan-row="head-stop"][data-system-id="${systemId}"]`);

async function clearBoxNotifs(page) {
  await page.evaluate(() => {
    const { $store } = document.querySelector('#app').__vue__;
    while ($store.state.game.boxNotifications.length) $store.commit('game/discardFirstBoxNotification');
  });
}

function boxLines(page) {
  return page.$$eval('.box-notification-item .plan-change-notif [data-line]', (els) => els.map((el) => ({
    key: el.dataset.line, text: el.textContent.trim(),
  })));
}

// Dijkstra over the client's lane list (same weights the plan router uses).
function shortest(page, from, to) {
  return page.evaluate(({ a, b }) => {
    const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
    const adj = new Map();
    edges.forEach((e) => {
      [[e.s1.id, e.s2.id], [e.s2.id, e.s1.id]].forEach(([x, y]) => {
        if (!adj.has(x)) adj.set(x, []);
        adj.get(x).push([y, e.weight]);
      });
    });
    const dist = new Map([[a, 0]]);
    const prev = new Map();
    const todo = new Set([a]);
    while (todo.size) {
      let cur = null;
      todo.forEach((n) => { if (cur === null || dist.get(n) < dist.get(cur)) cur = n; });
      todo.delete(cur);
      if (cur === b) break;
      (adj.get(cur) || []).forEach(([n, w]) => {
        const d = dist.get(cur) + w;
        if (!dist.has(n) || d < dist.get(n)) { dist.set(n, d); prev.set(n, cur); todo.add(n); }
      });
    }
    const path = [b];
    while (path[0] !== a) path.unshift(prev.get(path[0]));
    return path;
  }, { a: from, b: to });
}

// A simple path home → p1 → … → p{n} along real lanes where each hop is
// also the shortest route between its ends (so a single right-click on
// the next system routes exactly one hop).
function chainFrom(page, home, n) {
  return page.evaluate(({ start, len }) => {
    const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
    const adj = new Map();
    edges.forEach((e) => {
      [[e.s1.id, e.s2.id], [e.s2.id, e.s1.id]].forEach(([x, y]) => {
        if (!adj.has(x)) adj.set(x, []);
        adj.get(x).push([y, e.weight]);
      });
    });
    // Some lanes are longer than a detour through a neighbour (the router
    // then takes the detour): only follow a lane that clearly beats every
    // other way between its ends. Dijkstra from `a`, cut off at the lane.
    const laneIsRoute = (a, b, w) => {
      const dist = new Map([[a, 0]]);
      const todo = new Set([a]);
      while (todo.size) {
        let cur = null;
        todo.forEach((x) => { if (cur === null || dist.get(x) < dist.get(cur)) cur = x; });
        todo.delete(cur);
        if (dist.get(cur) >= w * 1.001) return true;
        for (const [nb, lw] of adj.get(cur) || []) {
          if (!(cur === a && nb === b)) {
            const d = dist.get(cur) + lw;
            if (nb === b && d <= w * 1.001) return false;
            if (!dist.has(nb) || d < dist.get(nb)) { dist.set(nb, d); todo.add(nb); }
          }
        }
      }
      return true;
    };
    const prev = new Map([[start, null]]);
    const depth = new Map([[start, 0]]);
    const todo = [start];
    while (todo.length) {
      const cur = todo.shift();
      if (depth.get(cur) === len) {
        const path = [];
        for (let x = cur; x !== null; x = prev.get(x)) path.unshift(x);
        return path;
      }
      (adj.get(cur) || []).forEach(([nb, w]) => {
        if (!prev.has(nb) && laneIsRoute(cur, nb, w)) {
          prev.set(nb, cur); depth.set(nb, depth.get(cur) + 1); todo.push(nb);
        }
      });
    }
    return null;
  }, { start: home, len: n });
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

test('agent plan: stops, hover pulse, remove / cancel / reorder with re-routing', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);

  // slowest speed: the head jump (O → A) stays in flight for the whole spec
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

  const path = await chainFrom(page, homeSystemId, 4);
  expect(path, 'no 4-hop route from home').toBeTruthy();
  const [O, A, B, C, D] = path;

  await page.evaluate((id) => {
    const app = document.querySelector('#app').__vue__;
    return app.$store.dispatch('game/selectCharacter', { vm: app, id });
  }, admiral);
  await expect(page.locator('.agent-plan')).toBeVisible();

  // Place one order the way the map does, then wait until the client's
  // copy of the agent has caught up (the next order routes from its
  // virtual position).
  const order = async (action, systemId) => {
    const before = (await serverQueue(page, admiral)).length;
    await page.evaluate(({ a, s }) => {
      document.querySelector('#app').__vue__.$root.$emit('map:addAction', a, { system: { id: s } });
    }, { a: action, s: systemId });
    await expect.poll(async () => (await serverQueue(page, admiral)).length).toBeGreaterThan(before);
    await page.waitForFunction(({ s }) => {
      const c = document.querySelector('#app').__vue__.$store.state.game.selectedCharacter;
      return c && c.actions.virtual_position === s;
    }, { s: systemId });
  };

  await test.step('orders from the map become stops: B, C (bombard + pillage), D', async () => {
    await order('jump', A);
    await order('jump', B);
    await order('jump', C);
    await order('raid', C);
    await order('loot', C);
    await order('jump', D);

    const q = await serverQueue(page, admiral);
    const routeAC = await shortest(page, A, C);
    // single right-clicks one hop at a time — each leg ends on a stop marker
    expect(describeQueue(q)).toEqual([
      `${O}>${A}*`, `${A}>${B}*`, `${B}>${C}*`, `raid@${C}`, `loot@${C}`, `${C}>${D}*`,
    ]);
    expect(routeAC.length).toBeGreaterThanOrEqual(2);

    await expect.poll(() => planRows(page)).toEqual([
      { kind: 'head', system: A, key: null, actions: [] },
      expect.objectContaining({ kind: 'stop', system: B, actions: [] }),
      expect.objectContaining({ kind: 'stop', system: C, actions: ['raid', 'loot'] }),
      expect.objectContaining({ kind: 'stop', system: D, actions: [] }),
    ]);
  });

  await test.step("the running action's progress ring is centered on its icon", async () => {
    const geometry = await page.evaluate(() => {
      const head = document.querySelector('.agent-plan .agent-plan-row[data-plan-row="head"] .agent-plan-icon');
      const ring = head.querySelector('.generic-circle-progress-container svg').getBoundingClientRect();
      const icon = head.querySelector(':scope > svg').getBoundingClientRect();
      const center = (r) => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
      return { ring: { ...center(ring), size: ring.width }, icon: { ...center(icon), size: icon.width } };
    });
    expect(Math.abs(geometry.ring.x - geometry.icon.x), JSON.stringify(geometry)).toBeLessThanOrEqual(0.5);
    expect(Math.abs(geometry.ring.y - geometry.icon.y), JSON.stringify(geometry)).toBeLessThanOrEqual(0.5);
    // the icon fits inside the stroke (20px circle, 3px stroke: 8.5px inner radius)
    expect(geometry.icon.size / 2).toBeLessThanOrEqual(8.5);
  });

  await test.step('each row says when the agent is done there; hovering says how long from now', async () => {
    const etas = await page.$$eval('.agent-plan .agent-plan-row', (els) => els.map((el) => {
      const box = el.getBoundingClientRect();
      const eta = el.querySelector('.agent-plan-eta').getBoundingClientRect();
      const name = el.querySelector('.agent-plan-name').getBoundingClientRect();
      return {
        text: el.querySelector('.agent-plan-eta').textContent.trim(),
        rightGap: Math.round(box.right - eta.right),
        nameLeftOfEta: name.right <= eta.left,
      };
    }));
    // A and B are jumps: dated. A bombard/pillage only gets its duration
    // when it starts, so C — and everything after it — can't be dated yet.
    expect(etas.map((e) => e.text === '—'), JSON.stringify(etas)).toEqual([false, false, true, true]);
    // one right-aligned column, names on the left
    expect(new Set(etas.map((e) => e.rightGap)).size, JSON.stringify(etas)).toBe(1);
    etas.forEach((e) => expect(e.nameLeftOfEta, JSON.stringify(etas)).toBe(true));

    const tooltipOf = async (locator) => {
      await page.mouse.move(10, 500);
      await locator.hover();
      const tip = page.locator('.tooltip .tooltip-inner').last();
      await expect(tip).toBeVisible();
      return (await tip.textContent()).trim();
    };
    const seconds = (text) => {
      const m = text.match(/^(?:(\d+) D )?(?:(\d+) H )?(?:(\d+) M )?(\d+)s$/);
      expect(m, `countdown "${text}"`).toBeTruthy();
      const [d, h, min, s] = m.slice(1).map((x) => Number(x || 0));
      return ((d * 24 + h) * 60 + min) * 60 + s;
    };
    const etaOf = (locator) => locator.locator('.agent-plan-eta');
    const head = page.locator('.agent-plan .agent-plan-row[data-plan-row="head"]');

    const headIn = seconds(await tooltipOf(etaOf(head)));
    const bIn = seconds(await tooltipOf(etaOf(row(page, B))));
    const readAt = Date.now();
    expect(bIn).toBeGreaterThan(headIn);
    // it counts down in wall-clock seconds
    await page.waitForTimeout(3000);
    const bLater = seconds(await tooltipOf(etaOf(row(page, B))));
    const elapsed = (Date.now() - readAt) / 1000;
    expect(Math.abs((bIn - bLater) - elapsed), `${bIn} → ${bLater} in ${elapsed}s`).toBeLessThanOrEqual(2);

    expect(await tooltipOf(etaOf(row(page, C)))).toContain('undetermined');
    expect(await tooltipOf(etaOf(row(page, D)))).toContain('not yet known');
    await page.mouse.move(10, 500);
  });

  await test.step('hovering a stop pulses its destination on the map, in its faction color', async () => {
    await row(page, C).hover();
    const pulse = () => page.evaluate(() => {
      const mesh = window.__rcMap.scene.getObjectByName('queue-destination-pulse');
      return {
        visible: mesh.visible,
        systemId: mesh.userData.systemId,
        faction: mesh.userData.faction,
        x: mesh.position.x,
        y: mesh.position.y,
        scale: mesh.scale.x,
        color: mesh.material.color.getHex(),
      };
    });
    const system = await page.evaluate((id) => {
      const s = window.__rcMap.data.systemsById.get(id);
      return { x: s.position.x, y: s.position.y, faction: s.faction || 'neutral' };
    }, C);

    const p1 = await pulse();
    expect(p1.visible).toBe(true);
    expect(p1.systemId).toBe(C);
    expect(p1.faction).toBe(system.faction);
    expect([p1.x, p1.y]).toEqual([system.x, system.y]);
    // it animates (grows and fades in a loop)
    await expect.poll(async () => (await pulse()).scale, { timeout: 3000 }).not.toBe(p1.scale);

    // It starts at the visible edge of the system's icon — sprites are
    // 0.4 × display_size_factor wide, textures drawn out to 87/128 of the
    // half-size — or a few pixels when zoomed out to dots, and grows to at
    // most 1.6× that. Sampled over a few periods (1.1 s each).
    const ring = await page.evaluate(async (id) => {
      const m = window.__rcMap;
      const mesh = m.scene.getObjectByName('queue-destination-pulse');
      const s = m.data.systemsById.get(id);
      const dsf = m.gameData.stellar_system.find((t) => t.key === s.type).display_size_factor;
      const px = (2 * m.camera.position.z * Math.tan((m.camera.fov / 2) * (Math.PI / 180)))
        / m.renderer.domElement.clientHeight;
      const scales = [];
      for (let i = 0; i < 60; i += 1) {
        scales.push(mesh.scale.x);
        await new Promise((r) => { setTimeout(r, 55); });
      }
      return { edge: 0.2 * dsf * (87 / 128), px, min: Math.min(...scales), max: Math.max(...scales) };
    }, C);
    const start = Math.max(ring.edge, 4 * ring.px);
    expect(ring.min, JSON.stringify(ring)).toBeGreaterThanOrEqual(start * 0.999);
    expect(ring.min, JSON.stringify(ring)).toBeLessThanOrEqual(start * 1.1);
    expect(ring.max, JSON.stringify(ring)).toBeLessThanOrEqual(start * 1.6 + 1e-9);
    // unowned systems: a soft gray, not white
    if (p1.faction === 'neutral') expect(p1.color).toBe(0x8c8c8c);

    // the head row pulses the head's destination
    await page.locator('.agent-plan .agent-plan-row[data-plan-row="head"]').hover();
    await expect.poll(async () => (await pulse()).systemId).toBe(A);

    // leaving the panel hides it
    await page.mouse.move(10, 500);
    await expect.poll(async () => (await pulse()).visible).toBe(false);
  });

  await test.step("hovering a stop's × marks what goes with it", async () => {
    await row(page, C).hover();
    await row(page, C).locator('.agent-plan-remove').hover();
    await expect(row(page, C)).toHaveClass(/is-doomed/);
    await expect(row(page, B)).not.toHaveClass(/is-doomed/);
    await page.mouse.move(10, 500);
    await expect(row(page, C)).not.toHaveClass(/is-doomed/);
  });

  await test.step('removing stop B: C is re-routed from A, the player is told what happened', async () => {
    await clearBoxNotifs(page);
    await row(page, B).hover();
    await row(page, B).locator('.agent-plan-remove').click();

    const routeAC = await shortest(page, A, C);
    const expectedJumps = routeAC.slice(1).map((s, i) => `${routeAC[i]}>${s}${s === C ? '*' : ''}`);
    await expect.poll(async () => describeQueue(await serverQueue(page, admiral))).toEqual([
      `${O}>${A}*`, ...expectedJumps, `raid@${C}`, `loot@${C}`, `${C}>${D}*`,
    ]);
    const q = await serverQueue(page, admiral);
    assertChained(q, O);

    await expect.poll(() => planRows(page)).toEqual([
      { kind: 'head', system: A, key: null, actions: [] },
      expect.objectContaining({ kind: 'stop', system: C, actions: ['raid', 'loot'] }),
      expect.objectContaining({ kind: 'stop', system: D, actions: [] }),
    ]);

    await expect(page.locator('.box-notification-item .plan-change-notif')).toBeVisible();
    const lines = await boxLines(page);
    expect(lines.map((l) => l.key)).toContain('removed_stop');
    if (routeAC.includes(B)) {
      // B is still on the way: say so, and how to avoid it
      const through = lines.find((l) => l.key === 'pass_through');
      expect(through, JSON.stringify(lines)).toBeTruthy();
      expect(through.text).toContain('passes through');
    } else {
      expect(lines.map((l) => l.key)).toContain('rerouted');
    }
  });

  await test.step('cancelling one action keeps the stop and its other action', async () => {
    await clearBoxNotifs(page);
    const bombard = row(page, C).locator('.agent-plan-action[data-action-type="raid"]');
    await bombard.hover();
    await bombard.locator('.agent-plan-cancel-action').click();

    await expect.poll(async () => (await serverQueue(page, admiral)).filter((a) => a.type !== 'jump')
      .map((a) => `${a.type}@${a.target}`)).toEqual([`loot@${C}`]);
    await expect.poll(async () => (await planRows(page)).find((r) => r.system === C).actions).toEqual(['loot']);
    await expect(page.locator('.box-notification-item [data-line="removed_action"]')).toBeVisible();
  });

  await test.step('dragging D above C re-routes both legs; the pillage follows C', async () => {
    await clearBoxNotifs(page);
    const from = await row(page, D).boundingBox();
    const to = await row(page, C).boundingBox();
    await page.mouse.move(from.x + 40, from.y + from.height / 2);
    await page.mouse.down();
    await page.mouse.move(from.x + 40, from.y + from.height / 2 + 4);
    await page.mouse.move(to.x + 40, to.y + to.height * 0.2, { steps: 8 });
    await page.mouse.up();

    const routeAD = await shortest(page, A, D);
    const routeDC = await shortest(page, D, C);
    const jumps = (r, stop) => r.slice(1).map((s, i) => `${r[i]}>${s}${s === stop ? '*' : ''}`);
    await expect.poll(async () => describeQueue(await serverQueue(page, admiral))).toEqual([
      `${O}>${A}*`, ...jumps(routeAD, D), ...jumps(routeDC, C), `loot@${C}`,
    ]);
    assertChained(await serverQueue(page, admiral), O);

    await expect.poll(async () => (await planRows(page)).map((r) => r.system)).toEqual([A, D, C]);
    const lines = await boxLines(page);
    expect(lines.map((l) => l.key)).toContain('moved');
  });

  await test.step('removing C takes its pillage with it', async () => {
    await clearBoxNotifs(page);
    await row(page, C).hover();
    await row(page, C).locator('.agent-plan-remove').click();

    await expect.poll(async () => (await serverQueue(page, admiral)).some((a) => a.type === 'loot')).toBe(false);
    await expect.poll(async () => (await planRows(page)).map((r) => r.system)).toEqual([A, D]);
    await expect(page.locator('.box-notification-item [data-line="removed_stop_actions"]')).toBeVisible();
  });

  await test.step('removing a stop that is still on the way: "passes through", explained', async () => {
    // from the end of the plan X, find stops Y then Z where the shortest
    // route X → Z runs through Y
    const queue = await serverQueue(page, admiral);
    const X = queue.slice(-1)[0].target;
    // Y and Z off the plan's current route: a Y an earlier leg also passes
    // through would (rightly) be reported on the way to that earlier stop
    const onRoute = [...new Set(queue.flatMap((a) => [a.source, a.target]))];
    const pick = await page.evaluate(({ x, taken }) => {
      const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
      const nb = new Map();
      edges.forEach((e) => {
        [[e.s1.id, e.s2.id, e.weight], [e.s2.id, e.s1.id, e.weight]].forEach(([a, b, w]) => {
          if (!nb.has(a)) nb.set(a, new Map());
          nb.get(a).set(b, w);
        });
      });
      for (const [y, wxy] of nb.get(x) || []) {
        if (taken.includes(y)) continue;
        for (const [z, wyz] of nb.get(y) || []) {
          if (z === x || taken.includes(z)) continue;
          const direct = (nb.get(x) || new Map()).get(z);
          // no shortcut X–Z, and no other neighbour of X closer to Z
          const alt = [...(nb.get(x) || new Map())].some(([w, wxw]) => w !== y && (nb.get(w) || new Map()).has(z)
            && wxw + nb.get(w).get(z) <= wxy + wyz);
          if (direct === undefined && !alt) return { y, z };
        }
      }
      return null;
    }, { x: X, taken: onRoute });
    if (!pick) {
      test.info().annotations.push({ type: 'skipped-step', description: `no forced two-hop route from ${X}` });
      return;
    }
    const { y: Y, z: Z } = pick;

    const routeXZ = await shortest(page, X, Z);
    expect(routeXZ, 'the pick must route through Y').toEqual([X, Y, Z]);

    await order('jump', Y);
    await order('jump', Z);
    await clearBoxNotifs(page);
    await row(page, Y).hover();
    await row(page, Y).locator('.agent-plan-remove').click();

    // Y is route now, not a stop
    await expect.poll(async () => describeQueue(await serverQueue(page, admiral)).slice(-2)).toEqual([`${X}>${Y}`, `${Y}>${Z}*`]);
    await expect.poll(async () => (await planRows(page)).some((r) => r.system === Y)).toBe(false);
    await expect(row(page, Z).locator('.agent-plan-via')).toContainText('1');

    await expect(page.locator('.box-notification-item [data-line="pass_through"]')).toBeVisible();
    const through = (await boxLines(page)).find((l) => l.key === 'pass_through');
    const names = await page.evaluate(({ y, z }) => {
      const byId = new Map(document.querySelector('#app').__vue__.$store.state.game.galaxy.stellar_systems.map((s) => [s.id, s.name]));
      return { y: byId.get(y), z: byId.get(z) };
    }, { y: Y, z: Z });
    expect(through.text).toContain(names.y);
    expect(through.text).toContain(names.z);
    expect(through.text).toContain('passes through');
  });

  await test.step('a stale edit is refused and changes nothing', async () => {
    const before = await serverQueue(page, admiral);
    const res = await playerPush(page, 'edit_character_actions', {
      character_id: admiral, keep_uid: 1, actions: [],
    });
    expect(res.ok).toBe(false);
    expect(res.error).toBe('stale_queue');
    expect(describeQueue(await serverQueue(page, admiral))).toEqual(describeQueue(before));
  });

  await test.step('a reload rebuilds the same stops from the saved markers', async () => {
    const before = await planRows(page);
    await page.reload();
    await waitConnected(page);
    await instrument(page);
    await page.evaluate((id) => {
      const app = document.querySelector('#app').__vue__;
      return app.$store.dispatch('game/selectCharacter', { vm: app, id });
    }, admiral);
    await expect.poll(async () => (await planRows(page)).map((r) => ({ ...r, key: null })))
      .toEqual(before.map((r) => ({ ...r, key: null })));
    const errors = await page.evaluate(() => window.__e2e.errors);
    expect(errors).toEqual([]);
  });
  await test.step('orders without stop markers (queued by older clients) are each their own stop', async () => {
    // three single hops sent without markers, as orders placed before
    // markers existed look after a restore (instance 185)
    const vp = (await serverQueue(page, admiral)).slice(-1)[0].target;
    const hops = await page.evaluate((start) => {
      const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
      const nb = (id) => edges.filter((e) => e.s1.id === id || e.s2.id === id).map((e) => (e.s1.id === id ? e.s2.id : e.s1.id));
      const path = [start];
      while (path.length < 4) {
        const next = nb(path[path.length - 1]).find((x) => !path.includes(x));
        if (next === undefined) break;
        path.push(next);
      }
      return path;
    }, vp);
    expect(hops.length, 'no 3-hop walk from the end of the plan').toBe(4);
    const res = await playerPush(page, 'add_character_actions', {
      character_id: admiral,
      actions: hops.slice(1).map((t, i) => ({ type: 'jump', data: { source: hops[i], target: t } })),
    });
    expect(res.ok, res.error).toBe(true);

    await expect.poll(async () => (await planRows(page)).slice(-3).map((r) => r.system)).toEqual(hops.slice(1));
    const last3 = page.locator('.agent-plan .agent-plan-row[data-plan-row="stop"]');
    for (const id of hops.slice(1)) {
      await expect(row(page, id).locator('.agent-plan-via')).toHaveCount(0);
    }
    expect(await last3.count()).toBeGreaterThanOrEqual(3);
  });

  await test.step('"stop here": every order after the running one is cancelled at once', async () => {
    await clearBoxNotifs(page);
    const head = (await serverQueue(page, admiral))[0];
    const stopHere = page.locator('.agent-plan .agent-plan-row[data-plan-row="head"] .agent-plan-stop-here');
    await page.locator('.agent-plan .agent-plan-row[data-plan-row="head"]').hover();
    await stopHere.hover();
    // every stop below is marked as going
    const doomed = await page.$$eval('.agent-plan .agent-plan-row[data-plan-row="stop"]', (els) => els.map((el) => el.classList.contains('is-doomed')));
    expect(doomed.length).toBeGreaterThan(0);
    expect(doomed.every(Boolean)).toBe(true);

    await stopHere.click();
    await expect.poll(async () => (await serverQueue(page, admiral)).map((a) => a.uid)).toEqual([head.uid]);
    await expect.poll(async () => (await planRows(page)).map((r) => r.kind)).toEqual(['head']);
    await expect(page.locator('.box-notification-item [data-line="cleared"]')).toBeVisible();
    await expect(page.locator('.agent-plan .agent-plan-stop-here')).toHaveCount(0);
  });
});
