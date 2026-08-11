// The fallback protocol: an account WITHOUT the slim_sync beta flag must
// get the legacy full player_player broadcast on construction orders —
// byte-identical behavior to the pre-delta wire protocol — and the
// client must sync via the refetch path. This is what every
// non-opted-in player runs in production, so it gets its own guard.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, instrument, counters, openSystem, playerPush, snapshot,
  pickBuildCandidates,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

let api;
let instanceId;
let homeSystemId;

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  // features: [] force-disables every beta flag on the account —
  // including slim_sync a previous spec may have enabled.
  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 500000, technology: 20000, ideology: 5000 },
    [],
  );
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});

test('non-beta account: orders sync via the legacy full-broadcast protocol', async ({ page, context, baseURL }) => {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);

  await page.goto('/portal/game');
  await waitConnected(page);
  await instrument(page);

  await openSystem(page, homeSystemId);
  const before = await snapshot(page);
  const c0 = await counters(page);

  // One legal order (patent purchase first if the picker says so).
  const candidates = await pickBuildCandidates(page);
  expect(candidates.length).toBeGreaterThanOrEqual(1);
  let placed = null;
  for (const cand of candidates) {
    if (!cand.patentOwned) {
      const patent = await playerPush(page, 'purchase_patent', { patent_key: cand.patent });
      if (!patent.ok) continue;
    }
    const res = await playerPush(page, 'order_building', {
      system_id: homeSystemId,
      production_data: {
        type: 'build', target_id: cand.body, tile_id: cand.tile, prod_key: cand.key, prod_level: 1,
      },
    });
    if (res.ok) { placed = cand; break; }
  }
  expect(placed, 'no build order accepted').toBeTruthy();

  // The legacy path still delivers: queue + tile + resources, via the
  // full broadcast and the coalesced refetch.
  await page.waitForFunction((id) => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    return s && s.id === id && s.queue && s.queue.queue && s.queue.queue.length >= 1;
  }, homeSystemId, { timeout: 10000 });

  const after = await snapshot(page);
  expect(after.credit.value).toBeLessThan(before.credit.value);

  // Protocol assertion: WITHOUT the beta flag there must be zero slim
  // deltas — the order arrived as a full player_player broadcast.
  const c1 = await counters(page);
  expect(c1.playerProduction - c0.playerProduction).toBe(0);
  expect(c1.playerPlayer - c0.playerPlayer).toBeGreaterThanOrEqual(1);
});
