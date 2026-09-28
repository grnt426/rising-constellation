// Writes to an agent that land while its action is starting/finishing.
//
// The action orchestrator runs the head action's start/finish hook on a
// copy of the character; its result used to REPLACE the agent's state,
// silently undoing anything that arrived in between (a fleet stance change,
// a ship completing, training XP, a fight's damage…). Now the agent merges
// the hook's result with those writes.
//
// Live check: a Navarch walks two hops; the dev-only orchestrator delay
// holds each start/finish hook for 4 s; a stance change is sent inside the
// window and must still be there once the hook lands — next to the hook's
// own effect (the jump progressing).
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

let api;
let instanceId;
let homeSystemId;

async function character(page, id) {
  const res = await playerPush(page, 'get_character', { character_id: id });
  if (!res.ok) throw new Error(`get_character: ${res.error}`);
  return res.data.character;
}

async function waitStatus(id, pred, what, timeoutMs = 90000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const cs = await api.charStatus(instanceId, id);
    if (pred(cs)) return cs;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(cs)}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

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

test('a stance change sent while the agent starts/finishes a jump is kept', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);
  const speed = await setSpeedCheat(page, 5);
  expect(speed.ok, speed.error).toBe(true);

  const admiral = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return st.player.characters.find((c) => c.type === 'admiral').id;
  });
  const [n1, n2] = await page.evaluate((home) => {
    const { edges } = document.querySelector('#app').__vue__.$store.state.game.galaxy;
    const nb = (id) => edges.filter((e) => e.s1.id === id || e.s2.id === id).map((e) => (e.s1.id === id ? e.s2.id : e.s1.id));
    const a = nb(home)[0];
    const b = nb(a).find((x) => x !== home);
    return [a, b];
  }, homeSystemId);
  expect(n2, 'no two-hop walk from home').toBeTruthy();

  const before = await character(page, admiral);
  expect(before.army.reaction).toBe('defend');

  // wide enough that a window noticed late (the second one opens right as
  // the first closes) still has room for the write
  await api.orchestratorDelay(instanceId, 4000);
  const add = await playerPush(page, 'add_character_actions', {
    character_id: admiral,
    actions: [
      { type: 'jump', data: { source: homeSystemId, target: n1 } },
      { type: 'jump', data: { source: n1, target: n2 } },
    ],
  });
  expect(add.ok, add.error).toBe(true);

  for (const [reaction, label] of [['attack_enemies', 'first'], ['fight_back', 'second']]) {
    await test.step(`${label} lock window: stance → ${reaction}`, async () => {
      const locked = await waitStatus(admiral, (cs) => cs.queue[0] === 'locked', 'a locked queue');
      const res = await playerPush(page, 'update_reaction', { character_id: admiral, reaction });
      expect(res.ok, res.error).toBe(true);
      // the stance change answered while the hook was still held
      const still = await api.charStatus(instanceId, admiral);
      expect(still.queue[0], 'the hook finished before the write — window missed').toBe('locked');

      const after = await waitStatus(admiral, (cs) => cs.queue[0] !== 'locked', 'the hook to land', 15000);
      // the write survived the hook's result
      expect(after.reaction).toBe(reaction);
      expect(locked.reaction).not.toBe(reaction);
    });
  }

  await api.orchestratorDelay(instanceId, 0);
  // …and so did the hooks' own effects: the walk completes as ordered
  const arrived = await waitStatus(admiral, (cs) => cs.system === n2 && cs.queue.length === 0, 'arrival at the second hop');
  expect(arrived.reaction).toBe('fight_back');
  const final = await character(page, admiral);
  expect(final.army.reaction).toBe('fight_back');
  const errors = await page.evaluate(() => window.__e2e.errors);
  expect(errors).toEqual([]);
});
