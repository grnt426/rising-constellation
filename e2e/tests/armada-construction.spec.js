// Armadas and shipyards: an armada does not leave while one of its
// Navarchs has a ship under construction — from either side, through the
// real client pipeline (socket push → Player.Agent → ArmadaImpl gates →
// stellar system → character agents):
//   - a member is building: a jump ordered on any member is refused
//     (armada_member_docking), until the ship is delivered;
//   - a jump is queued: a ship ordered for any member is refused
//     (armada_busy), even sent on the heels of the jump — before the
//     jump's start hook has pulled the members out of the system. That
//     window used to let the order through: the armada left with the ship
//     still in the yard, and the ship was delivered to a fleet elsewhere;
//   - the armada then arrives together, with nothing on order.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const SHIP = 'transport_1';

// Buy the patent chain down to `patentKey`, root first.
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

// Server truth for one Navarch: where it is, what it does, its yard.
async function fleet(page, characterId) {
  const res = await playerPush(page, 'get_character', { character_id: characterId });
  if (!res.ok) throw new Error(`get_character failed: ${res.error}`);
  const c = res.data.character;
  const tiles = c.army.tiles || [];
  return {
    system: c.system,
    status: c.action_status,
    planned: tiles.filter((t) => t.ship_status === 'planned').length,
    filled: tiles.filter((t) => t.ship_status === 'filled').length,
    emptyTiles: tiles.filter((t) => t.ship_status === 'empty').map((t) => t.id),
  };
}

// Push several player-channel events in one task, so they reach the
// server back to back; resolves with 'ok' or the refusal reason of each.
function pushTogether(page, events) {
  return page.evaluate((list) => {
    const socket = document.querySelector('#app').__vue__.$socket.player;
    return Promise.all(list.map(([event, payload]) => new Promise((resolve) => {
      socket.push(event, payload)
        .receive('ok', () => resolve('ok'))
        .receive('error', (err) => resolve(err && err.reason))
        .receive('timeout', () => resolve('timeout'));
    })));
  }, events);
}

test('armada: no departure while a member builds, no building once a jump is queued', async ({ page, context, request, baseURL }) => {
  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  // two own navarchs at home, pre-formed as an armada
  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 500000, technology: 100000, ideology: 5000 },
    null,
    2,
    { own: [2] },
  );
  const instanceId = fixture.instance_id;
  const home = fixture.system.id;

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);

    await page.goto('/portal/game');
    await waitConnected(page);

    // Flash speed is still real time — compress the yard and the transit.
    const cheat = await setSpeedCheat(page, 10);
    expect(cheat.ok, `set_speed failed: ${cheat.error}`).toBe(true);

    const [lead, member] = fixture.armadas.own[0];
    const patents = await ensurePatents(page, SHIP);
    expect(patents.ok, `${SHIP} patent chain failed: ${patents.error}`).toBe(true);

    const neighbor = await page.evaluate((h) => {
      const g = document.querySelector('#app').__vue__.$store.state.game.galaxy;
      for (const e of (g.edges || [])) {
        if (e.s1.id === h) return e.s2.id;
        if (e.s2.id === h) return e.s1.id;
      }
      return null;
    }, home);
    expect(neighbor, 'no adjacent system found in galaxy edges').toBeTruthy();

    const jump = (characterId) => ['add_character_actions', {
      character_id: characterId,
      actions: [{ type: 'jump', data: { source: home, target: neighbor } }],
    }];
    const ship = (characterId, tileId) => ['order_ship', {
      system_id: home,
      production_data: { target_id: characterId, tile_id: tileId, prod_key: SHIP },
    }];

    // ---- a member is building: nobody can take the armada away ----
    const [firstTile, secondTile] = (await fleet(page, member)).emptyTiles;
    expect(secondTile, 'the member needs two empty army tiles').toBeTruthy();

    expect(await pushTogether(page, [ship(member, firstTile)])).toEqual(['ok']);
    expect(await pushTogether(page, [jump(lead), jump(member)]))
      .toEqual(['armada_member_docking', 'armada_member_docking']);

    // ...until the ship is delivered
    await expect.poll(async () => {
      const f = await fleet(page, member);
      return f.filled === 1 && f.status === 'idle' ? 'delivered' : `waiting:${f.status}`;
    }, { timeout: 180000, intervals: [3000] }).toBe('delivered');

    // ---- a jump is queued: nobody can start building ----
    const [leadTile] = (await fleet(page, lead)).emptyTiles;

    expect(await pushTogether(page, [jump(lead), ship(member, secondTile), ship(lead, leadTile)]))
      .toEqual(['ok', 'armada_busy', 'armada_busy']);

    // ---- the armada arrives together, with nothing on order ----
    await expect.poll(async () => {
      const fleets = await Promise.all([lead, member].map((id) => fleet(page, id)));
      if (fleets.some((f) => f.system !== neighbor)) return 'in transit';
      if (fleets.some((f) => f.status !== 'idle')) return 'not idle';
      return 'arrived';
    }, { timeout: 180000, intervals: [3000] }).toBe('arrived');

    expect(await fleet(page, lead)).toMatchObject({ planned: 0, filled: 0 });
    expect(await fleet(page, member)).toMatchObject({ planned: 0, filled: 1 });
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});
