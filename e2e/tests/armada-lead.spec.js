// Armada lead (docs/armadas.md §8.6) through the real client: the lead
// is stored and shown, an order given to a resting member hands it the
// lead, an order given to a riding member joins the lead's plan, a
// click on the moving armada selects the lead, riding members' map tags
// are hidden, and a member's panel has a button that selects the lead.
//
// The fixture pre-forms one own armada of three in the starting system
// (armada_layout: {own: [3]}). Orders go through the map's own
// addCharacterAction — the code every order path (right-click, system
// view, orders list, mobile radial) ends in.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, openSystem, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

function game(page, fn, arg) {
  return page.evaluate(fn, arg);
}

function roster(page) {
  return game(page, () => document.querySelector('#app').__vue__.$store.state.game.player.characters
    .filter((c) => c.type === 'admiral' && c.armada)
    .map((c) => ({
      id: c.id, name: c.name, status: c.action_status, system: c.system, armada: c.armada,
    })));
}

async function serverCharacter(page, id) {
  const res = await playerPush(page, 'get_character', { character_id: id });
  if (!res.ok) throw new Error(`get_character failed: ${res.error}`);
  return res.data.character;
}

async function select(page, id) {
  await game(page, (cid) => {
    const app = document.querySelector('#app').__vue__;
    return app.$store.dispatch('game/selectCharacter', { vm: app, id: cid });
  }, id);
  await page.waitForFunction((cid) => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedCharacter;
    return s && s.id === cid;
  }, id);
}

function neighbors(page, systemId) {
  return game(page, (id) => document.querySelector('#app').__vue__.$store.state.game.galaxy.edges
    .filter((e) => e.s1.id === id || e.s2.id === id)
    .map((e) => (e.s1.id === id ? e.s2.id : e.s1.id)), systemId);
}

// an order from the selection, as a right-click on the system gives it
function orderMove(page, systemId) {
  return game(page, (id) => {
    const map = window.__rcMap;
    map.addCharacterAction('jump', { system: map.data.systemsById.get(id) });
  }, systemId);
}

test('armada lead: hand-off, routed orders, map click, panel shortcut, crown', async ({ page, context, request, baseURL }) => {
  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(PLAYER.email, null, null, 3, { own: [3] });
  const instanceId = fixture.instance_id;
  const home = fixture.system.id;

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);
    await page.goto('/portal/game');
    await waitConnected(page);
    await page.waitForFunction(() => !!window.__rcMap, null, { timeout: 60000 });

    // record the toasts the client shows
    await page.evaluate(() => {
      window.__toasts = [];
      const toasted = document.querySelector('#app').__vue__.$toasted;
      ['info', 'error'].forEach((kind) => {
        const original = toasted[kind].bind(toasted);
        toasted[kind] = (message, ...rest) => {
          window.__toasts.push({ kind, message });
          return original(message, ...rest);
        };
      });
    });

    // ---- formation names the forming Navarch lead ----
    const members = await roster(page);
    expect(members.length).toBe(3);
    const formedBy = members[0].armada.id;
    expect(members.every((m) => m.armada.lead_id === formedBy)).toBe(true);
    const [lead, rider] = members.map((m) => m.id).filter((id) => id !== formedBy);

    // slow travel: the armada must still be under way for the routed
    // order, the tags and the click
    expect((await setSpeedCheat(page, 0.25)).ok).toBe(true);
    const [first] = await neighbors(page, home);
    const second = (await neighbors(page, first)).find((id) => id !== home);

    // ---- a resting member given orders takes the lead ----
    await select(page, lead);
    await orderMove(page, first);
    await expect.poll(async () => (await roster(page)).find((m) => m.id === lead).status).toBe('moving');
    expect((await serverCharacter(page, lead)).armada.lead_id).toBe(lead);
    await expect.poll(async () => (await roster(page)).filter((m) => m.id !== lead).every((m) => m.status === 'attached'))
      .toBe(true);

    // ---- a riding member's order joins the lead's plan ----
    await select(page, rider);
    await orderMove(page, second);
    await expect.poll(async () => (await serverCharacter(page, lead)).actions.queue.length).toBe(2);
    expect((await serverCharacter(page, rider)).actions.queue.length).toBe(0);
    await expect.poll(() => page.evaluate(() => window.__toasts.filter((t) => t.kind === 'info').length)).toBe(1);
    expect(await page.evaluate(() => window.__toasts.filter((t) => t.kind === 'error'))).toEqual([]);

    // ---- riding members' map tags are hidden ----
    const tags = await game(page, (ids) => {
      const block = window.__rcMap.getBlockByName('Character');
      const { characters } = document.querySelector('#app').__vue__.$store.state.game.player;
      return ids.map((id) => block.names[characters.find((c) => c.id === id).name].visible);
    }, [formedBy, rider]);
    expect(tags).toEqual([false, false]);

    // ---- the rider's panel names the lead; its button selects it ----
    const leadName = (await roster(page)).find((m) => m.id === lead).name;
    await expect(page.locator('.selection-armada-lead')).toContainText(leadName, { ignoreCase: true });
    await page.click('.selection-select-lead');
    await page.waitForFunction((id) => document.querySelector('#app').__vue__.$store.state.game.selectedCharacter.id === id, lead);
    await expect(page.locator('.selection-armada-lead.is-self')).toBeVisible();
    await expect(page.locator('.selection-select-lead')).toHaveCount(0);
    // the lead's card and its row in the agents list wear the crown
    await expect(page.locator('.armada.is-lead').first()).toBeVisible();

    // ---- a click on the moving armada selects its lead ----
    await game(page, () => document.querySelector('#app').__vue__.$store.dispatch('game/unselectCharacter'));
    const point = await game(page, (id) => {
      const map = window.__rcMap;
      const { sprite } = map.getBlockByName('Character').movingMeshes.get(id);
      // closest zoom a player can reach (map.minZ)
      map.setCameraPosition(sprite.position.x, sprite.position.y, map.minZ);
      map.onZ(map.minZ);
      const canvas = map.renderer.domElement.getBoundingClientRect();
      const v = sprite.position.clone().project(map.camera);
      return { x: canvas.left + ((v.x + 1) / 2) * canvas.width, y: canvas.top + ((1 - v.y) / 2) * canvas.height };
    }, lead);
    await page.mouse.move(point.x - 4, point.y - 4);
    await page.mouse.move(point.x, point.y);
    await page.mouse.down();
    await page.mouse.up();
    await page.waitForFunction((id) => {
      const s = document.querySelector('#app').__vue__.$store.state.game.selectedCharacter;
      return s && s.id === id;
    }, lead, { timeout: 10000 });

    // ---- the whole armada reaches the routed destination; the lead stays ----
    expect((await setSpeedCheat(page, 20)).ok).toBe(true);
    await expect.poll(async () => (await roster(page)).every((m) => m.system === second && m.status === 'idle'), {
      timeout: 240000, intervals: [2000],
    }).toBe(true);
    expect((await serverCharacter(page, formedBy)).armada.lead_id).toBe(lead);

    // ---- the system view crowns the lead ----
    await openSystem(page, second);
    await expect(page.locator('.lead-pip')).toHaveCount(1);
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});
