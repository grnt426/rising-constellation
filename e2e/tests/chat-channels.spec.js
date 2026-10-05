// Faction chat: channels, the posts the game makes for a player, and
// sightings that go stale by themselves.
//
//   - the chat has a tab per channel plus "All"; a message goes to the
//     channel of the tab it was typed in and shows nowhere else but "All";
//   - planting a Claim flag posts in Claims once; the flag leads back to
//     its post; removing the flag marks the post as released;
//   - Shift+click on an enemy agent in a system reports it in Spotted as a
//     LIVE chip, once; nothing of the agent's identity beyond what the
//     system view shows reaches the client;
//   - when that agent flies off, its chip turns "last known" by itself;
//   - the fleet it flies off in shows on the S.L.S.D. with its next stop
//     (and nothing else of who it is), can be reported as heading there,
//     is followed while in range, and turns "last known" once it leaves
//     range or arrives;
//   - hovering a blip pulses its next stop on the map; another faction's
//     blip also says "shift-click to report".
//
// Two real players drive it: user1 (reports) and user3, whose lone
// hostile Navarch the fixture parks in user1's home system.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected, openSystem } = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ENEMY = { email: 'user3@abc', password: 'user3dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// tab order: all, general, claims, spotted, aid, ask
const TAB = { all: 0, general: 1, claims: 2, spotted: 3, aid: 4, ask: 5 };

let api;
let instanceId;
let homeSystemId;

// ---- helpers ----------------------------------------------------------

async function enterGame(page, context, baseURL, email) {
  const reg = await api.registrationToken(email, instanceId);
  const start = await api.gameStartPayload(email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
}

function factionPush(page, event, payload) {
  return page.evaluate(({ event: ev, payload: pl }) => new Promise((resolve) => {
    document.querySelector('#app').__vue__.$socket.faction
      .push(ev, pl)
      .receive('ok', (data) => resolve({ ok: true, data }))
      .receive('error', (err) => resolve({ ok: false, error: err && err.reason }))
      .receive('timeout', () => resolve({ ok: false, error: 'timeout' }));
  }), { event, payload });
}

function messages(page, channel) {
  return page.evaluate((ch) => {
    const { chat } = document.querySelector('#app').__vue__.$store.state.game.faction;
    return JSON.parse(JSON.stringify(chat.filter((m) => !ch || m.channel === ch)));
  }, channel);
}

function sightings(page) {
  return page.evaluate(() => JSON.parse(JSON.stringify(
    document.querySelector('#app').__vue__.$store.state.game.sightings,
  )));
}

const sighting = async (page, id) => (await sightings(page)).find((s) => s.id === id) || null;

const tab = (page, key) => page.locator('.chat-tab').nth(TAB[key]);
const line = (page, id) => page.locator(`.chat-message[data-message-id="${id}"]`);

function toasts(page) {
  return page.$$eval('.toasted', (els) => els.map((el) => el.textContent.trim()));
}

// The chat column and what surrounds it, for a human to look at afterwards.
function shot(page, name, clip = { x: 0, y: 0, width: 460, height: 420 }) {
  return page.screenshot({ path: test.info().outputPath(`${name}.png`), clip });
}

const exactly = (text) => new RegExp(`^\\s*${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`);

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);
  await api.login(ENEMY.email, ENEMY.password);

  const fixture = await api.createAgentFixture(PLAYER.email);
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('chat channels, claim posts and sightings that go stale', async ({ page, context, browser, baseURL }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error.message)));
  // a click that can't land should fail the step, not sit out the test budget
  page.setDefaultTimeout(30000);
  await enterGame(page, context, baseURL, PLAYER.email);

  await test.step('a tab per channel; a message lives in the channel it was typed in', async () => {
    await expect(page.locator('.chat-tab')).toHaveCount(6);
    await tab(page, 'all').click();
    await expect(tab(page, 'all')).toHaveClass(/is-active/);

    await tab(page, 'aid').click();
    await expect(tab(page, 'aid')).toHaveClass(/is-active/);
    await page.locator('.chat-composer').click();
    await page.keyboard.type('need technology for the next patent');
    await page.keyboard.press('Enter');

    await expect.poll(() => messages(page, 'aid')).toHaveLength(1);
    const [sent] = await messages(page, 'aid');
    expect(sent.message).toBe('need technology for the next patent');
    expect(typeof sent.id).toBe('number');

    await expect(line(page, sent.id)).toBeVisible();
    // not in another channel…
    await tab(page, 'general').click();
    await expect(line(page, sent.id)).toHaveCount(0);
    // …but in the combined view, marked with its channel
    await tab(page, 'all').click();
    await expect(line(page, sent.id).locator('.chat-channel-tag.is-aid')).toBeVisible();

    // typed in "All", a message goes to General
    await page.locator('.chat-composer').click();
    await page.keyboard.type('hello');
    await page.keyboard.press('Enter');
    // (General also holds the fixture's "cheats enabled" system line)
    await expect.poll(async () => (await messages(page, 'general')).map((m) => m.message)).toContain('hello');
  });

  let claimId;
  await test.step('a Claim flag is announced in Claims, once, and leads back to its post', async () => {
    const place = await factionPush(page, 'place_icon', { system_id: homeSystemId, icon_kind: 'flag' });
    expect(place.ok, `place_icon failed: ${place.error}`).toBe(true);

    await expect.poll(() => messages(page, 'claims')).toHaveLength(1);
    const [claim] = await messages(page, 'claims');
    claimId = claim.id;
    expect(claim.message).toBe(`[[sys:${homeSystemId}]]`);
    expect(claim.meta).toEqual({ kind: 'claim', system_id: homeSystemId });

    // planting the flag one already holds says nothing new
    const again = await factionPush(page, 'place_icon', { system_id: homeSystemId, icon_kind: 'flag' });
    expect(again.ok).toBe(true);
    // another marker is not a claim
    expect(await messages(page, 'claims')).toHaveLength(1);

    // from the flag to the post: the chat opens on it
    await page.evaluate((id) => {
      document.querySelector('#app').__vue__.$root.$emit('chat:showClaim', id);
    }, homeSystemId);
    await expect(page.locator('.chat-container')).toHaveClass(/is-pinned/);
    await expect(tab(page, 'claims')).toHaveClass(/is-active/);
    await expect(line(page, claimId)).toHaveClass(/is-flash/);
    await expect(line(page, claimId)).not.toHaveClass(/is-stale/);
    await expect(line(page, claimId).locator('.chat-ref-system')).toBeVisible();
    await shot(page, '1-claim-live');
  });

  await test.step('removing the flag marks the claim as released', async () => {
    const remove = await factionPush(page, 'remove_icon', { system_id: homeSystemId });
    expect(remove.ok, `remove_icon failed: ${remove.error}`).toBe(true);
    await expect(line(page, claimId)).toHaveClass(/is-stale/);
    await shot(page, '2-claim-released');
  });

  await test.step('a blip on the map answers the pointer: next stop pulsed, hint, Shift+click reports it', async () => {
    // Deterministic stand-in for a fleet in flight: a blip drawn in open
    // space next to home, client-side only. The server knows of no fleet
    // there, so the report must come back "no longer on the S.L.S.D." —
    // which proves the whole pointer path up to the server and back.
    await page.evaluate((id) => {
      document.querySelector('#app').__vue__.$root.$emit('map:centerToSystem', id);
    }, homeSystemId);
    await page.waitForTimeout(1200);

    const spot = await page.evaluate((id) => {
      const map = window.__rcMap;
      const home = map.data.systems.find((s) => s.id === id);
      // The direction around home with the most room to the nearest
      // system. Half-step angles: never on the screen-centre crosshair's
      // arms (home is centred), which are page elements above the canvas.
      const candidates = Array.from({ length: 16 }, (_, i) => {
        const a = ((i + 0.5) / 16) * 2 * Math.PI;
        const x = home.position.x + Math.cos(a) * 1.6;
        const y = home.position.y + Math.sin(a) * 1.6;
        const room = Math.min(...map.data.systems.map((s) => Math.hypot(s.position.x - x, s.position.y - y)));
        return { x, y, room };
      }).sort((p, q) => q.room - p.room);
      const { x, y } = candidates[0];
      // …and flying to the system nearest home
      const dist = (s) => Math.hypot(s.position.x - home.position.x, s.position.y - home.position.y);
      const target = map.data.systems.filter((s) => s.id !== home.id).sort((a, b) => dist(a) - dist(b))[0];

      map.data.updateDetectedObjects([
        { faction: 'myrmezir', position: { x, y }, angle: 0.5, target_system_id: target.id },
      ]);

      window.__e2eFactionPushes = [];
      const { faction } = document.querySelector('#app').__vue__.$socket;
      const push = faction.push.bind(faction);
      faction.push = (event, payload) => {
        window.__e2eFactionPushes.push({ event, payload });
        return push(event, payload);
      };

      return { x, y, room: candidates[0].room, target: target.id };
    }, homeSystemId);
    expect(spot.room, 'needs open space beside home for the stand-in blip').toBeGreaterThan(0.8);

    // drawn by the map's own frame loop
    await page.waitForFunction(() => {
      const block = window.__rcMap.blocks.find((b) => b.name === 'DetectedObject');
      const group = block && block.getGroupByName('detected-objects');
      return group && group.visible && group.children.length === 1;
    });

    const screen = await page.evaluate(({ x, y }) => {
      const map = window.__rcMap;
      const v = map.controls.target.clone().set(x, y, 0).project(map.camera);
      return { x: ((v.x + 1) / 2) * window.innerWidth, y: ((1 - v.y) / 2) * window.innerHeight };
    }, spot);

    const hint = page.locator('.map-blip-hint');
    const pulsed = () => page.evaluate(() => window.__rcMap.destinationPulse.systemId);
    const toastsBefore = (await toasts(page)).length;

    // plain hover: where the fleet is going pulses on the map, and the
    // pulse keeps running while the pointer wanders over the blip
    await page.mouse.move(screen.x - 40, screen.y - 40);
    expect(await pulsed()).toBeNull();
    await page.mouse.move(screen.x, screen.y, { steps: 4 });
    await expect.poll(pulsed).toBe(spot.target);
    await expect(hint).toHaveText('shift-click to report');
    const startedAt = await page.evaluate(() => window.__rcMap.destinationPulse.startedAt);
    await page.mouse.move(screen.x + 1, screen.y + 1);
    await page.mouse.move(screen.x, screen.y);
    expect(await page.evaluate(() => window.__rcMap.destinationPulse.startedAt)).toBe(startedAt);

    // off the blip, both go
    await page.mouse.move(screen.x - 60, screen.y - 60, { steps: 3 });
    await expect.poll(pulsed).toBeNull();
    await expect(hint).toBeHidden();

    // With Shift held a blip takes the pointer even where it flies over a
    // system's dot or label, and says what the click will do.
    await page.keyboard.down('Shift');
    await page.mouse.move(screen.x, screen.y, { steps: 4 });
    await expect(hint).toBeVisible();
    await expect.poll(pulsed).toBe(spot.target);
    await shot(page, '0-blip-hint', { x: Math.max(0, screen.x - 230), y: Math.max(0, screen.y - 150), width: 520, height: 300 });
    await page.mouse.click(screen.x, screen.y);
    await page.keyboard.up('Shift');

    await expect.poll(() => page.evaluate(() => window.__e2eFactionPushes)).toHaveLength(1);
    const [sent] = await page.evaluate(() => window.__e2eFactionPushes);
    expect(sent.event).toBe('report_fleet');
    expect(sent.payload.faction).toBe('myrmezir');
    expect(sent.payload.x).toBeCloseTo(spot.x, 3);
    expect(sent.payload.y).toBeCloseTo(spot.y, 3);
    // nothing is there for the server: the player is told, nothing is posted
    await expect.poll(async () => (await toasts(page)).length).toBeGreaterThan(toastsBefore);
    expect(await sightings(page)).toHaveLength(0);

    // a plain click on a blip reports nothing
    await page.mouse.click(screen.x, screen.y);
    await page.waitForTimeout(300);
    expect(await page.evaluate(() => window.__e2eFactionPushes)).toHaveLength(1);

    // a faction-mate's fleet says where it goes too, but is not one to report
    await page.evaluate(() => {
      const map = window.__rcMap;
      const [blip] = map.data.detectedObjects;
      const own = document.querySelector('#app').__vue__.$store.state.game.playerFaction;
      map.data.updateDetectedObjects([{ ...blip, faction: own }]);
    });
    await page.waitForFunction(() => {
      const block = window.__rcMap.blocks.find((b) => b.name === 'DetectedObject');
      const [wrapper] = block.getGroupByName('detected-objects').children;
      return wrapper && wrapper.gameObject.data.reportable === false;
    });
    await page.mouse.move(screen.x - 40, screen.y - 40);
    await page.mouse.move(screen.x, screen.y, { steps: 4 });
    await expect.poll(pulsed).toBe(spot.target);
    await expect(hint).toBeHidden();
    await page.keyboard.down('Shift');
    await page.mouse.click(screen.x, screen.y);
    await page.keyboard.up('Shift');
    await page.waitForTimeout(300);
    expect(await page.evaluate(() => window.__e2eFactionPushes)).toHaveLength(1);

    // touch has no hover: a tap on a fleet flashes its next stop for a moment
    await page.mouse.move(screen.x - 200, screen.y + 150);
    await expect.poll(pulsed).toBeNull();
    await page.evaluate(({ x, y }) => {
      const canvas = window.__rcMap.renderer.domElement;
      const tap = (type) => canvas.dispatchEvent(new PointerEvent(type, {
        pointerType: 'touch', pointerId: 7, clientX: x, clientY: y, button: 0, buttons: type === 'pointerdown' ? 1 : 0,
        bubbles: true, cancelable: true,
      }));
      tap('pointerdown');
      tap('pointerup');
    }, screen);
    expect(await pulsed()).toBe(spot.target);
    await expect.poll(pulsed, { timeout: 5000 }).toBeNull();

    await page.evaluate(() => window.__rcMap.data.updateDetectedObjects([]));
    await expect(hint).toBeHidden();
  });

  let lone;
  let agentSightingId;
  await test.step('Shift+click on an enemy agent reports it in Spotted, live, once', async () => {
    await openSystem(page, homeSystemId);

    // user3's lone Navarch: the only foreign agent whose owner has just one there
    lone = await page.evaluate(() => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const foreign = st.selectedSystem.characters.filter((c) => c.owner.faction !== st.playerFaction);
      const c = foreign.find((x) => foreign.filter((y) => y.owner.id === x.owner.id).length === 1);
      return c ? { id: c.id, name: c.name, type: c.type, faction: c.owner.faction } : null;
    });
    expect(lone, 'the fixture parks a lone hostile navarch at home').not.toBeNull();
    expect(lone.type).toBe('admiral');

    const badge = page.locator('.action-item')
      .filter({ has: page.locator('.action-label .name', { hasText: exactly(lone.name) }) })
      .locator('.round-icon');
    await badge.click({ modifiers: ['Shift'] });

    await expect.poll(() => sightings(page)).toHaveLength(1);
    const [seen] = await sightings(page);
    agentSightingId = seen.id;
    expect(seen).toMatchObject({
      kind: 'agent',
      status: 'live',
      agent_type: 'admiral',
      faction: lone.faction,
      name: lone.name,
      system_id: homeSystemId,
    });

    const [post] = await messages(page, 'spotted');
    expect(post.message).toBe(`[[spot:${seen.id}]]`);
    expect(post.id).toBe(seen.message_id);

    // the chat opened on the report, with a live chip
    await expect(tab(page, 'spotted')).toHaveClass(/is-active/);
    const chip = line(page, post.id).locator('.chat-ref-sighting');
    await expect(chip).toBeVisible();
    await expect(chip).not.toHaveClass(/is-lost/);
    await expect(chip.locator('.chat-ref-doubt')).toHaveCount(0);
    await shot(page, '3-agent-live');

    // reporting it again posts nothing: the player is shown the report
    await badge.click({ modifiers: ['Shift'] });
    await expect.poll(async () => (await toasts(page)).length).toBeGreaterThan(0);
    expect(await messages(page, 'spotted')).toHaveLength(1);
    expect(await sightings(page)).toHaveLength(1);

    // close the system view the way a player does, back to the galaxy
    await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      return app.$store.dispatch('game/closeSystem', app);
    });
  });

  let fleetSightingId;
  await test.step('the enemy flies off: the agent chip turns last-known, the fleet can be reported', async () => {
    const enemyContext = await browser.newContext();
    const enemyPage = await enemyContext.newPage();
    await enterGame(enemyPage, enemyContext, baseURL, ENEMY.email);

    // Order user3's Navarch to the nearest other system, through the real
    // client path (select, then the map's jump order).
    await enemyPage.waitForFunction(() => window.__rcMap && window.__rcMap.data.systems.length > 1);
    const order = await enemyPage.evaluate(async (navId) => {
      const app = document.querySelector('#app').__vue__;
      const map = window.__rcMap;
      const st = app.$store.state.game;
      const nav = st.player.characters.find((c) => c.id === navId);
      const here = map.data.systems.find((s) => s.id === nav.system);
      const dist = (s) => Math.hypot(s.position.x - here.position.x, s.position.y - here.position.y);
      const target = map.data.systems.filter((s) => s.id !== here.id).sort((a, b) => dist(a) - dist(b))[0];

      await app.$store.dispatch('game/selectCharacter', { vm: app, id: navId });
      for (let i = 0; i < 100 && !(st.selectedCharacter && st.selectedCharacter.id === navId); i += 1) {
        // eslint-disable-next-line no-await-in-loop
        await new Promise((r) => setTimeout(r, 100));
      }

      map.addCharacterAction('jump', { system: target });
      return { target: target.id, distance: dist(target) };
    }, lone.id);

    // it has left: no longer standing in the system
    await enemyPage.waitForFunction((navId) => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const nav = st.player.characters.find((c) => c.id === navId);
      return nav && nav.system == null;
    }, lone.id, { timeout: 60000 });

    // the agent report goes stale by itself
    await expect.poll(async () => (await sighting(page, agentSightingId)).status, { timeout: 60000 })
      .toBe('lost');
    const gone = await sighting(page, agentSightingId);
    expect(gone.reason).toBe('hidden');
    expect(typeof gone.lost_at).toBe('number');

    const agentPost = (await messages(page, 'spotted'))[0];
    await tab(page, 'spotted').click();
    const agentChip = line(page, agentPost.id).locator('.chat-ref-sighting');
    await expect(agentChip).toHaveClass(/is-lost/);
    await expect(agentChip.locator('.chat-ref-doubt')).toHaveText('?');

    // its fleet is a blip on user1's S.L.S.D.: report that one
    await page.waitForFunction((faction) => window.__rcMap
      && window.__rcMap.data.detectedObjects.some((b) => b.faction === faction), lone.faction, { timeout: 60000 });
    const blip = await page.evaluate((faction) => {
      const b = window.__rcMap.data.detectedObjects.find((x) => x.faction === faction);
      return {
        faction: b.faction, x: b.position.x, y: b.position.y, target: b.target_system_id, keys: Object.keys(b).sort(),
      };
    }, lone.faction);
    // a blip says where it is going, and nothing of who it is
    expect(blip.keys).toEqual(['angle', 'faction', 'position', 'target_system_id']);
    expect(blip.target).toBe(order.target);

    const report = await factionPush(page, 'report_fleet', { x: blip.x, y: blip.y, faction: blip.faction });
    expect(report.ok, `report_fleet failed: ${report.error}`).toBe(true);
    expect(report.data.duplicate).toBe(false);
    fleetSightingId = report.data.sighting_id;

    await expect.poll(() => sighting(page, fleetSightingId)).not.toBeNull();
    const fleet = await sighting(page, fleetSightingId);
    expect(fleet).toMatchObject({ kind: 'fleet', agent_type: 'admiral', faction: lone.faction });
    // heading to its next system — and nothing says which agent it is
    expect(fleet.system_id).toBe(order.target);
    expect(fleet).not.toHaveProperty('character_id');
    expect(fleet).not.toHaveProperty('target_position');
    expect(fleet.name).toBeNull();
    await page.evaluate((id) => {
      document.querySelector('#app').__vue__.$root.$emit('chat:showMessage', id);
    }, report.data.message_id);
    await shot(page, '4-fleet-live-agent-lost');

    // a second report of the same blip is the same sighting
    const twice = await factionPush(page, 'report_fleet', { x: blip.x, y: blip.y, faction: blip.faction });
    if (twice.ok) {
      expect(twice.data).toMatchObject({ sighting_id: fleetSightingId, duplicate: true });
    } else {
      // it left the S.L.S.D. in between: there is nothing left to point at
      expect(twice.error).toBe('contact_lost');
    }

    // and it ends as "last known" once out of range or arrived
    await expect.poll(async () => (await sighting(page, fleetSightingId)).status, { timeout: 5 * 60 * 1000 })
      .toBe('lost');
    const lost = await sighting(page, fleetSightingId);
    expect(['arrived', 'out_of_range']).toContain(lost.reason);
    expect(lost.position).toEqual({ x: expect.any(Number), y: expect.any(Number) });

    const fleetPost = (await messages(page, 'spotted')).find((m) => m.id === report.data.message_id);
    const fleetChip = line(page, fleetPost.id).locator('.chat-ref-sighting');
    await expect(fleetChip).toHaveClass(/is-lost/);

    // the whole story, as the "All" tab tells it
    await tab(page, 'all').click();
    await page.locator('.chat-container').hover();
    await shot(page, '5-all-expanded');

    await enemyContext.close();
  });

  expect(errors, `page errors: ${errors.join(' | ')}`).toEqual([]);
});
