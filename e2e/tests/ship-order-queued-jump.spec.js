// A fleet under construction does not move, and a fleet that has been
// told to move does not start construction. The first half was always
// enforced (every order refuses a docking Navarch); the second was open in
// the moment between a jump being accepted and its start hook taking the
// Navarch out of the system: a ship ordered right behind the jump was
// planned, the Navarch left with it, and the yard delivered it to the
// fleet one system away.
//
// A lone Navarch, through the real client pipeline (socket push →
// Player.Agent → StellarSystem.can_order_ship → character agent):
//   - at rest, a ship order goes through, and while the ship is in the
//     yard a jump is refused (unable_to_move);
//   - once the ship is delivered, a jump and a ship order sent back to
//     back: the jump is accepted, the ship is refused
//     (character_not_idle_or_docking);
//   - the Navarch arrives with what it had, and nothing on order.
// The armada side of the same rule: armada-construction.spec.js.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, setSpeedCheat, ensurePatents, fleet, pushTogether, neighborOf,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };
const SHIP = 'transport_1';

test('ship orders: refused for a Navarch with a jump queued', async ({ page, context, request, baseURL }) => {
  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 500000, technology: 100000, ideology: 5000 },
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

    const patents = await ensurePatents(page, SHIP);
    expect(patents.ok, `${SHIP} patent chain failed: ${patents.error}`).toBe(true);

    const navarch = await page.evaluate(() => document.querySelector('#app').__vue__.$store.state.game
      .player.characters.find((c) => c.type === 'admiral' && c.status === 'on_board').id);
    const neighbor = await neighborOf(page, home);
    expect(neighbor, 'no adjacent system found in galaxy edges').toBeTruthy();

    const jump = ['add_character_actions', {
      character_id: navarch,
      actions: [{ type: 'jump', data: { source: home, target: neighbor } }],
    }];
    const ship = (tileId) => ['order_ship', {
      system_id: home,
      production_data: { target_id: navarch, tile_id: tileId, prod_key: SHIP },
    }];

    // ---- in the yard: the Navarch does not move ----
    const [firstTile, secondTile] = (await fleet(page, navarch)).emptyTiles;
    expect(secondTile, 'the navarch needs two empty army tiles').toBeTruthy();

    expect(await pushTogether(page, [ship(firstTile)])).toEqual(['ok']);
    expect(await pushTogether(page, [jump])).toEqual(['unable_to_move']);

    await expect.poll(async () => {
      const f = await fleet(page, navarch);
      return f.filled === 1 && f.status === 'idle' ? 'delivered' : `waiting:${f.status}`;
    }, { timeout: 180000, intervals: [3000] }).toBe('delivered');

    // ---- told to move: no ship behind the jump ----
    expect(await pushTogether(page, [jump, ship(secondTile)]))
      .toEqual(['ok', 'character_not_idle_or_docking']);

    // ---- it arrives with the ship it had, and nothing on order ----
    await expect.poll(async () => {
      const f = await fleet(page, navarch);
      if (f.system !== neighbor) return 'in transit';
      return f.status === 'idle' ? 'arrived' : 'not idle';
    }, { timeout: 180000, intervals: [3000] }).toBe('arrived');

    expect(await fleet(page, navarch)).toMatchObject({ planned: 0, filled: 1 });
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});
