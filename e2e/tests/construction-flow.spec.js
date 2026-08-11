// The synthetic-player scenario: constructions (order / upgrade-reject /
// cancel), agent hire + movement, multiple systems, colonization + orders
// in a second system, legitimate income change, and quit-via-reload +
// rejoin persistence — on a Flash-speed instance fabricated by the dev
// harness (time limit and victory neutralized so it can't end mid-test).
//
// Assertions read the Vuex store from inside the live SPA: that is the
// state the templates render from, one step past the broadcast pipeline
// under test (socket → handleReceive → applyProductionDelta/refetch →
// frozen commit). Counters wrapped around the real socket verify HOW the
// client synced: slim player_production deltas on the hot path, full
// get_system only from the trailing settle sync / background sync.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, counters, openSystem, playerPush, snapshot, serverPlayer,
  pickBuildCandidates, waitTilePlanned, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// Buy every unowned patent on the ancestor chain of `patentKey`,
// root-first — the real progression path.
async function ensurePatents(page, patentKey) {
  const chain = await page.evaluate((key) => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const owned = new Set(st.player.patents || []);
    const byKey = new Map((st.data.patent || []).map((p) => [p.key, p]));
    const out = [];
    let cur = key;
    while (cur && !owned.has(cur)) {
      out.unshift(cur);
      const p = byKey.get(cur);
      cur = p ? p.ancestor : null;
    }
    return out;
  }, patentKey);
  for (const key of chain) {
    const res = await playerPush(page, 'purchase_patent', { patent_key: key });
    if (!res.ok && res.error !== 'patent_already_purchased') {
      return { ok: false, error: `${key}: ${res.error}` };
    }
  }
  return { ok: true };
}

// Same, for the doctrine tree (bought with ideology, then equipped as a
// policy to actually apply its bonuses).
async function ensureDoctrines(page, doctrineKey) {
  const chain = await page.evaluate((key) => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const owned = new Set(st.player.doctrines || []);
    const byKey = new Map((st.data.doctrine || []).map((d) => [d.key, d]));
    const out = [];
    let cur = key;
    while (cur && !owned.has(cur)) {
      out.unshift(cur);
      const d = byKey.get(cur);
      cur = d ? d.ancestor : null;
    }
    return out;
  }, doctrineKey);
  for (const key of chain) {
    const res = await playerPush(page, 'purchase_doctrine', { doctrine_key: key });
    if (!res.ok && res.error !== 'doctrine_already_purchased') {
      return { ok: false, error: `${key}: ${res.error}` };
    }
  }
  return { ok: true };
}

// Order one legal building in the given (already selected) system,
// buying the level-1 patent first when the player doesn't own it yet —
// the real progression flow for a fresh player. Returns the spot or null.
async function orderOneBuild(page, systemId) {
  const candidates = await pickBuildCandidates(page);
  for (const cand of candidates) {
    if (!cand.patentOwned) {
      const patent = await playerPush(page, 'purchase_patent', { patent_key: cand.patent });
      if (!patent.ok) continue; // e.g. price scaled past our technology
    }
    const res = await playerPush(page, 'order_building', {
      system_id: systemId,
      production_data: {
        type: 'build', target_id: cand.body, tile_id: cand.tile, prod_key: cand.key, prod_level: 1,
      },
    });
    if (res.ok) {
      await waitTilePlanned(page, cand);
      return cand;
    }
  }
  return null;
}

let api;
let instanceId;
let homeSystemId;

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 500000, technology: 20000, ideology: 5000 },
    // Opt into the slim-sync beta: this whole spec exercises the
    // player_production delta protocol. legacy-sync.spec.js covers the
    // fallback protocol for accounts without the flag.
    ['slim_sync'],
  );
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});

test('synthetic player: construct, move, colonize, earn, rejoin', async ({ page, context, baseURL }) => {
  // ---- enter the game -------------------------------------------------
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);

  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);

  // Compress game time so ship production / travel / colonization fit
  // the test budget (creator-tier cheat; the fixture enables cheats).
  const speed = await setSpeedCheat(page, 5);
  expect(speed.ok, `set_speed failed: ${speed.error}`).toBe(true);

  const boot = await snapshot(page);
  expect(boot.frozen.player).toBe(true);
  expect(boot.systems.length).toBeGreaterThanOrEqual(1);

  // ---- constructions in the home system -------------------------------
  await test.step('order constructions (slim delta, no refetch storm)', async () => {
    await openSystem(page, homeSystemId);
    const before = await snapshot(page);
    const c0 = await counters(page);

    // Order up to three legal builds, re-deriving the next legal spot
    // from the (delta-patched) store after each accepted order. Each
    // waitTilePlanned inside asserts the slim delta flipped the tile
    // within a broadcast round trip — no full refetch involved.
    const placedSpots = [];
    for (let i = 0; i < 3; i++) {
      const spot = await orderOneBuild(page, homeSystemId);
      if (!spot) break;
      placedSpots.push(spot);
    }
    const ordered = placedSpots.length;
    expect(ordered).toBeGreaterThanOrEqual(2);

    const after = await snapshot(page);
    expect(after.credit.value).toBeLessThan(before.credit.value);
    expect(after.frozen.system).toBe(true);

    const c1 = await counters(page);
    expect(c1.playerProduction - c0.playerProduction).toBeGreaterThanOrEqual(ordered);
    // Construction orders must not fan out into per-broadcast refetches:
    // allow the trailing settle sync, one for openSystem, and the
    // coalesced reloads legitimately triggered by full player_player
    // broadcasts (patent purchases in this step).
    const fullBroadcasts = c1.playerPlayer - c0.playerPlayer;
    expect(c1.getSystem - c0.getSystem).toBeLessThanOrEqual(2 + fullBroadcasts * 2);

    // An intentionally-unknown building key must come back as a clean
    // error (regression guard: this used to CRASH the player agent and
    // reset the player to genesis state).
    const badSpot = placedSpots[0];
    const bad = await playerPush(page, 'order_building', {
      system_id: homeSystemId,
      production_data: {
        type: 'build', target_id: badSpot.body, tile_id: badSpot.tile, prod_key: 'hypergate', prod_level: 99,
      },
    });
    expect(bad.ok).toBe(false);
    expect(bad.error).toBeTruthy();
    // The player must still be fully functional after the rejection.
    const alive = await serverPlayer(page);
    expect(alive.stellar_systems.length).toBeGreaterThanOrEqual(1);

  });

  await test.step('cancel a queued construction (refund via slim delta)', async () => {
    const before = await snapshot(page);
    expect(before.selected.queue.length).toBeGreaterThanOrEqual(1);
    const victim = before.selected.queue[before.selected.queue.length - 1];

    const res = await playerPush(page, 'cancel_production', {
      system_id: homeSystemId, production_id: victim.id,
    });
    expect(res.ok).toBe(true);

    await page.waitForFunction(({ n }) => {
      const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
      return s && s.queue && s.queue.queue && s.queue.queue.length === n;
    }, { n: before.selected.queue.length - 1 }, { timeout: 10000 });

    const after = await snapshot(page);
    expect(after.credit.value).toBeGreaterThan(before.credit.value);
    expect(after.selected.queue.find((q) => q.id === victim.id)).toBeUndefined();
  });

  // ---- agent hire + movement -----------------------------------------
  let navarchId;
  let neighborId;

  await test.step('move the navarch to an adjacent system', async () => {
    // A fresh player's max_admirals is 0 (capacity comes from
    // progression), so hiring from the deck is correctly rejected by the
    // market. The fixture pre-places an on-board admiral through the
    // convert_character path — that's our navarch.
    navarchId = await page.evaluate(() => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const c = (st.player.characters || []).find((x) => x.type === 'admiral');
      return c ? c.id : null;
    });
    expect(navarchId, 'fixture did not place an admiral').toBeTruthy();

    // Give the navarch a colonization ship first — the fixture mints an
    // empty army and colonization silently self-cancels without a
    // transport_1 aboard. This also exercises the ship branch of the
    // slim production delta.
    const patents = await ensurePatents(page, 'transport_1');
    expect(patents.ok, `transport_1 patent chain failed: ${patents.error}`).toBe(true);

    const charRes = await playerPush(page, 'get_character', { character_id: navarchId });
    expect(charRes.ok).toBe(true);
    const emptyTile = (charRes.data.character.army.tiles || []).find((t) => t.ship_status === 'empty');
    expect(emptyTile, 'no empty army tile on the navarch').toBeTruthy();

    const shipOrder = await playerPush(page, 'order_ship', {
      system_id: homeSystemId,
      production_data: { target_id: navarchId, tile_id: emptyTile.id, prod_key: 'transport_1' },
    });
    expect(shipOrder.ok, `order_ship failed: ${shipOrder.error}`).toBe(true);

    // The slim delta must also refresh the ROSTER entry (player.characters),
    // not just the selected character — the docking status and planned
    // count feed the agent cards, map labels, and market sell list.
    await page.waitForFunction((id) => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const c = (st.player.characters || []).find((x) => x.id === id);
      return !!c && (c.action_status === 'docking' || (c.army_size && c.army_size.planned >= 1));
    }, navarchId, { timeout: 10000 });

    // Ship completion fills the army tile and undocks the navarch.
    await expect.poll(async () => {
      const res = await playerPush(page, 'get_character', { character_id: navarchId });
      if (!res.ok) return `error:${res.error}`;
      const c = res.data.character;
      const hasShip = (c.army.tiles || []).some((t) => t.ship && t.ship.key === 'transport_1');
      return hasShip && c.action_status !== 'docking' ? 'ready' : `waiting:${c.action_status}`;
    }, { timeout: 180000, intervals: [3000] }).toBe('ready');

    // Choose a direct neighbor from the galaxy edge list (edges carry
    // nested system objects: {s1: {id,...}, s2: {id,...}, weight}).
    neighborId = await page.evaluate((home) => {
      const g = document.querySelector('#app').__vue__.$store.state.game.galaxy;
      for (const e of (g.edges || [])) {
        const a = e.s1 && e.s1.id;
        const b = e.s2 && e.s2.id;
        if (a === home) return b;
        if (b === home) return a;
      }
      return null;
    }, homeSystemId);
    expect(neighborId, 'no adjacent system found in galaxy edges').toBeTruthy();

    const move = await playerPush(page, 'add_character_actions', {
      character_id: navarchId,
      actions: [{ type: 'jump', data: { source: homeSystemId, target: neighborId } }],
    });
    expect(move.ok, `jump failed: ${move.error}`).toBe(true);

    // Arrival: character.system is null in transit, then the target id.
    await expect.poll(async () => {
      const res = await playerPush(page, 'get_character', { character_id: navarchId });
      return res.ok ? res.data.character.system : `error:${res.error}`;
    }, { timeout: 180000, intervals: [3000] }).toBe(neighborId);
  });

  // ---- multiple systems ----------------------------------------------
  await test.step('open several systems', async () => {
    await openSystem(page, neighborId);
    let snap = await snapshot(page);
    expect(snap.selected.id).toBe(neighborId);

    await openSystem(page, homeSystemId);
    snap = await snapshot(page);
    expect(snap.selected.id).toBe(homeSystemId);
  });

  // ---- income legitimately changing ----------------------------------
  await test.step('income accrues and rate reacts to the economy', async () => {
    const s0 = await serverPlayer(page);
    // Flash speed: ~1.5 s per unit-time; 12 s of wall clock is measurable.
    await page.waitForTimeout(12000);
    const s1 = await serverPlayer(page);
    if (s0.credit.change > 0) {
      expect(s1.credit.value).toBeGreaterThan(s0.credit.value);
    } else {
      // Whatever the sign of income, the value must move with it.
      expect(s1.credit.value).not.toBe(s0.credit.value);
    }
  });

  // ---- second owned system: colonize, then order there ----------------
  await test.step('colonize a neutral neighbor and order a construction there', async () => {
    // Find a neutral direct neighbor to colonize (skip if the map offers
    // none near home — the fixture map is large, so this is unlikely).
    const target = await page.evaluate(({ home }) => {
      const st = document.querySelector('#app').__vue__.$store.state.game;
      const g = st.galaxy;
      const owned = new Set((st.player.stellar_systems || []).map((s) => s.id));
      const byId = new Map((g.stellar_systems || []).map((s) => [s.id, s]));
      const out = [];
      for (const e of (g.edges || [])) {
        const a = e.s1 && e.s1.id;
        const b = e.s2 && e.s2.id;
        if (a === home) out.push(b);
        if (b === home) out.push(a);
      }
      return out.find((id) => {
        const sys = byId.get(id);
        return sys && !owned.has(id) && !sys.faction;
      }) || out.find((id) => !owned.has(id)) || null;
    }, { home: homeSystemId });

    test.skip(!target, 'no neutral neighbor available to colonize');

    // A fresh player has no spare system slot (max_systems comes from
    // the expansion doctrine line): buy agent → system_1 with ideology,
    // add a second policy slot, and equip BOTH — `agent` must stay
    // equipped because the fixture's pre-placed characters already sit
    // at the zero base caps, and update_policies validates the roster
    // against the new policy set.
    const doctrines = await ensureDoctrines(page, 'system_1');
    expect(doctrines.ok, `doctrine chain failed: ${doctrines.error}`).toBe(true);
    const slot = await playerPush(page, 'purchase_policy_slot', {});
    expect(slot.ok, `purchase_policy_slot failed: ${slot.error}`).toBe(true);
    const equip = await playerPush(page, 'update_policies', { doctrines_key: ['agent', 'system_1'] });
    expect(equip.ok, `update_policies failed: ${equip.error}`).toBe(true);

    // Move the navarch there (it may already be there) and colonize.
    const whereRes = await playerPush(page, 'get_character', { character_id: navarchId });
    const from = whereRes.data.character.system;
    const actions = [];
    if (from !== target) actions.push({ type: 'jump', data: { source: from, target } });
    actions.push({ type: 'colonization', data: { target } });

    const order = await playerPush(page, 'add_character_actions', { character_id: navarchId, actions });
    expect(order.ok, `colonization order failed: ${order.error}`).toBe(true);

    const c0 = await counters(page);
    // Colonization takes real game time at Flash speed; while waiting,
    // the 60 s background silent sync should fire at least once.
    await expect.poll(async () => {
      const player = await serverPlayer(page);
      return player.stellar_systems.length;
    }, { timeout: 240000, intervals: [5000] }).toBeGreaterThanOrEqual(2);

    const c1 = await counters(page);
    expect(c1.getPlayer).toBeGreaterThan(c0.getPlayer); // background sync ran

    // Order a construction in the NEW system through the same slim path
    // (a fresh colony has no infrastructure, so the picker will lead
    // with an infra building on tile 1).
    await openSystem(page, target);
    const spot = await orderOneBuild(page, target);
    expect(spot, 'no legal build accepted in colonized system').toBeTruthy();
  });

  // ---- quit (reload) + rejoin ----------------------------------------
  await test.step('reload the page and verify state re-primes identically', async () => {
    const preSrv = await serverPlayer(page);
    const pre = await snapshot(page);

    await page.reload();
    await waitConnected(page);
    await instrument(page);

    const postSrv = await serverPlayer(page);
    const post = await snapshot(page);

    // Persistent facts must survive the rejoin exactly.
    expect(post.systems.map((s) => s.id).sort()).toEqual(pre.systems.map((s) => s.id).sort());
    expect(postSrv.characters.map((c) => c.id).sort()).toEqual(preSrv.characters.map((c) => c.id).sort());
    const navPre = preSrv.characters.find((c) => c.id === navarchId);
    const navPost = postSrv.characters.find((c) => c.id === navarchId);
    expect(navPost.system).toBe(navPre.system);

    // Credit keeps ticking between the two reads; allow generous drift.
    const drift = Math.abs(postSrv.credit.value - preSrv.credit.value);
    const tolerance = Math.max(200, Math.abs(preSrv.credit.change) * 60);
    expect(drift).toBeLessThanOrEqual(tolerance);

    // The rejoin re-primed the store (fresh frozen player) with no errors.
    expect(post.frozen.player).toBe(true);
    const c = await counters(page);
    expect(c.errors).toEqual([]);
  });
});
