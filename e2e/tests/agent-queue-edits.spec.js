// Agent action-queue edits against the live engine: cancels and new orders
// that race the action orchestrator.
//
// While the orchestrator runs an action's start/finish hook, the
// character's queue is LOCKED and the hook's result replaces the whole
// character when it lands. Edits used to be applied in that window,
// acknowledged, then silently overwritten. Now:
//   - an edit during the lock waits (the channel retries) and is applied
//     once the lock clears, if that happens within 3 s;
//   - otherwise it fails with `agent_busy` ("...No changes made.") and
//     nothing changes;
//   - a cancel names the last action to keep by uid, so it still means the
//     same thing if the head finished before the server applied it;
//   - malformed cancel payloads are refused without crashing the agent.
//
// The lock window is widened on demand with the dev-only orchestrator
// delay; `charStatus` (gov-debug) is the one view that shows the raw
// `locked` head.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const BUSY_TEXT = 'The agent was busy while recalculating the action queue. No changes made.';

let api;
let instanceId;
let homeSystemId;

// ---- helpers ----------------------------------------------------------

const jump = (source, target) => ({ type: 'jump', data: { source, target } });

async function serverQueue(page, characterId) {
  const res = await playerPush(page, 'get_character', { character_id: characterId });
  if (!res.ok) throw new Error(`get_character: ${res.error}`);
  const { actions } = res.data.character;
  return {
    vpos: actions.virtual_position,
    queue: actions.queue.map((a) => ({ type: a.type, source: a.data.source, target: a.data.target, uid: a.uid })),
  };
}

const hops = (q) => q.queue.map((a) => `${a.source}>${a.target}`);

// n jumps from `from` along `path`, turning back at either end.
function walk(path, from, n) {
  let i = path.indexOf(from);
  let dir = i === path.length - 1 ? -1 : 1;
  const out = [];
  for (let k = 0; k < n; k++) {
    if (i + dir < 0 || i + dir >= path.length) dir = -dir;
    out.push({ ...jump(path[i], path[i + dir]), data: { source: path[i], target: path[i + dir], stop: true } });
    i += dir;
  }
  return out;
}

async function addWalk(page, characterId, path, n) {
  const { vpos } = await serverQueue(page, characterId);
  const actions = walk(path, vpos, n);
  const res = await playerPush(page, 'add_character_actions', { character_id: characterId, actions });
  expect(res.ok, `add ${JSON.stringify(actions)}: ${res.error}`).toBe(true);
  return actions;
}

// A simple path home → p1 → … → p{n} along real lanes (BFS).
function chainFrom(page, home, n) {
  return page.evaluate(({ start, len }) => {
    const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
    const adj = new Map();
    edges.forEach((e) => {
      const a = e.s1.id;
      const b = e.s2.id;
      if (!adj.has(a)) adj.set(a, []);
      if (!adj.has(b)) adj.set(b, []);
      adj.get(a).push(b);
      adj.get(b).push(a);
    });
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
      (adj.get(cur) || []).forEach((nb) => {
        if (!prev.has(nb)) {
          prev.set(nb, cur);
          depth.set(nb, depth.get(cur) + 1);
          todo.push(nb);
        }
      });
    }
    return null;
  }, { start: home, len: n });
}

async function waitLocked(characterId, timeoutMs = 90000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const cs = await api.charStatus(instanceId, characterId);
    if (cs.queue[0] === 'locked') return cs;
    if (Date.now() > deadline) throw new Error(`queue never locked: ${JSON.stringify(cs)}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

async function waitUnlocked(characterId, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const cs = await api.charStatus(instanceId, characterId);
    if (cs.queue[0] !== 'locked') return cs;
    if (Date.now() > deadline) throw new Error('queue stayed locked');
    await new Promise((r) => setTimeout(r, 100));
  }
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
  if (api && instanceId) {
    await api.orchestratorDelay(instanceId, 0).catch(() => {});
    await api.finishInstance(ADMIN.email, instanceId);
  }
});

test('agent queue edits never get acknowledged and then lost', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);

  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);
  // 1×: a hop takes 45 s+, so the head can't land mid-step while the
  // queue is being inspected; later steps speed up when they need hops
  // to land.
  const setSpeed = async (mult) => {
    const res = await setSpeedCheat(page, mult);
    expect(res.ok, res.error).toBe(true);
  };
  await setSpeed(1);

  const admiral = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return st.player.characters.find((c) => c.type === 'admiral').id;
  });
  const path = await chainFrom(page, homeSystemId, 4);
  expect(path, 'no 4-hop route from home').toBeTruthy();

  await test.step('malformed cancels are refused and change nothing', async () => {
    await addWalk(page, admiral, path, 2);
    const before = await serverQueue(page, admiral);

    for (const payload of [{ index: -1 }, { index: 0 }, { index: '1' }, { keep_uid: '1' }, {}]) {
      const res = await playerPush(page, 'clear_character_actions', { character_id: admiral, ...payload });
      expect(res.ok, JSON.stringify(payload)).toBe(false);
      expect(res.error, JSON.stringify(payload)).toBe('invalid_payload');
    }

    // unchanged — apart from the head landing in the meantime
    const after = await serverQueue(page, admiral);
    const beforeUids = before.queue.map((a) => a.uid);
    const afterUids = after.queue.map((a) => a.uid);
    expect([beforeUids, beforeUids.slice(1)]).toContainEqual(afterUids);
    expect(after.queue.every((a) => Number.isInteger(a.uid)), 'every queued action carries a uid').toBe(true);
  });

  await test.step('UI cancel (plan panel): removing a stop keeps the head and everything before it', async () => {
    const have = (await serverQueue(page, admiral)).queue.length;
    await addWalk(page, admiral, path, 4 - have);
    const q = await serverQueue(page, admiral);
    expect(q.queue.length).toBe(4);

    await page.evaluate((id) => {
      const app = document.querySelector('#app').__vue__;
      window.__edits = [];
      window.__editReplies = [];
      const orig = app.$socket.player.push.bind(app.$socket.player);
      app.$socket.player.push = (ev, pl) => {
        const push = orig(ev, pl);
        if (ev === 'edit_character_actions') {
          window.__edits.push(pl);
          const t = Date.now();
          push.receive('ok', () => window.__editReplies.push({ ok: true, ms: Date.now() - t }));
          push.receive('error', (e) => window.__editReplies.push({ ok: false, reason: e.reason, ms: Date.now() - t }));
        }
        return push;
      };
      return app.$store.dispatch('game/selectCharacter', { vm: app, id });
    }, admiral);

    // head row + one row per remaining stop (each jump here is its own order)
    const stops = page.locator('.agent-plan .agent-plan-row[data-plan-row="stop"]');
    await expect(stops).toHaveCount(3);

    // remove the third entry's stop: only that stop goes — the fourth is
    // re-routed from where the second ends
    await stops.nth(1).hover();
    await stops.nth(1).locator('.agent-plan-remove').click();

    await expect.poll(async () => (await serverQueue(page, admiral)).queue.some((a) => a.uid === q.queue[2].uid)).toBe(false);
    const after = await serverQueue(page, admiral);
    // the head and the second entry are untouched (same uids)
    expect(after.queue.map((a) => a.uid).slice(0, 2)).toEqual([q.queue[0].uid, q.queue[1].uid].slice(0, Math.min(2, after.queue.length)));
    // the plan still ends where the fourth entry ended
    expect(after.vpos).toBe(q.vpos);

    const [payload] = await page.evaluate(() => window.__edits);
    expect(payload.keep_uid).toBe(q.queue[0].uid);
    expect(payload.actions[0].uid).toBe(q.queue[1].uid);

    // back to a plain 2-entry queue for the next step
    await playerPush(page, 'clear_character_actions', { character_id: admiral, keep_uid: q.queue[1].uid });
  });

  await test.step('a cancel still means the same after the head finished', async () => {
    await addWalk(page, admiral, path, 3);
    await setSpeed(5);
    const q = await serverQueue(page, admiral);
    const [head, second] = q.queue;

    // the player looks at [head, second, ...] and clicks the third entry;
    // meanwhile the head lands
    await expect.poll(async () => (await serverQueue(page, admiral)).queue.some((a) => a.uid === head.uid), {
      timeout: 150000,
    }).toBe(false);

    // the stale index alone would now keep [second, third]; the uid keeps [second]
    const res = await playerPush(page, 'clear_character_actions', {
      character_id: admiral, index: 2, keep_uid: second.uid,
    });
    expect(res.ok, res.error).toBe(true);
    const expected = [`${second.source}>${second.target}`];
    expect(hops(await serverQueue(page, admiral))).toEqual(expected);

    // a uid that already ran no longer identifies anything: refused
    const stale = await playerPush(page, 'clear_character_actions', { character_id: admiral, keep_uid: head.uid });
    expect(stale.ok).toBe(false);
    expect(stale.error).toBe('stale_queue');
    expect(hops(await serverQueue(page, admiral))).toEqual(expected);
  });

  await test.step('an order sent while the queue is locked waits and is applied', async () => {
    await addWalk(page, admiral, path, 1);
    await api.orchestratorDelay(instanceId, 1500);

    // next lock: the head finishing or the next one starting
    await waitLocked(admiral);
    const { vpos } = await serverQueue(page, admiral);
    const order = walk(path, vpos, 1);
    const t0 = Date.now();
    const res = await playerPush(page, 'add_character_actions', { character_id: admiral, actions: order });
    const waited = Date.now() - t0;

    expect(res.ok, `order during the lock: ${res.error}`).toBe(true);
    expect(waited, 'the reply came before the lock cleared').toBeLessThan(3500);

    await waitUnlocked(admiral);
    const q = await serverQueue(page, admiral);
    // the acknowledged order survived the hook's state replacement
    expect(hops(q)[hops(q).length - 1]).toBe(`${order[0].data.source}>${order[0].data.target}`);
    expect(q.vpos).toBe(order[0].data.target);
  });

  await test.step('a lock held past 3 s: the UI reports "busy, no changes made", nothing changes', async () => {
    await api.orchestratorDelay(instanceId, 0);
    await waitUnlocked(admiral);
    await addWalk(page, admiral, path, 3);
    await api.orchestratorDelay(instanceId, 4500);

    // the next lock (current head finishing / next one starting)
    const locked = await waitLocked(admiral);
    const before = locked.queue.filter((t) => t !== 'locked');
    const stops = page.locator('.agent-plan .agent-plan-row[data-plan-row="stop"]');
    await expect.poll(() => stops.count()).toBeGreaterThan(0);

    const replies0 = await page.evaluate(() => window.__editReplies.length);
    await stops.last().hover();
    await stops.last().locator('.agent-plan-remove').click();

    const toast = page.locator('.toasted', { hasText: BUSY_TEXT });
    await expect(toast).toBeVisible({ timeout: 8000 });
    // server-side: ~3 s of retries, then the busy refusal
    const reply = await page.evaluate((n) => window.__editReplies[n], replies0);
    expect(reply.ok).toBe(false);
    expect(reply.reason).toBe('agent_busy');
    expect(reply.ms).toBeGreaterThanOrEqual(2800);
    expect(reply.ms).toBeLessThan(4000);

    await api.orchestratorDelay(instanceId, 0);
    const after = await waitUnlocked(admiral);
    // nothing was cut: every queued entry except (possibly) the hook's own
    // head transition is still there
    expect(after.queue.length).toBeGreaterThanOrEqual(before.length - 1);
    expect(after.queue.length).toBeGreaterThan(1);

    const errors = await page.evaluate(() => window.__e2e.errors);
    expect(errors).toEqual([]);
  });
});
