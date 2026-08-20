// One-off debug probe: boot a fixture, enter the game, dump the store /
// game-data shapes the spec helpers depend on, and try one deck-hire and
// one build order with raw error output. Extend freely when a spec step
// fails for unclear reasons. Run: node probe.js (cleans up its instance).
const { chromium, request } = require('@playwright/test');
const { Api } = require('./helpers/api');
const { seedGameCookies, waitConnected, openSystem } = require('./helpers/game');
const config = require('./playwright.config.js');

const baseURL = `http://localhost:${config.PHOENIX_PORT}`;

(async () => {
  const req = await request.newContext();
  const api = new Api(req, baseURL);
  await api.login('admin@abc', 'admindev');
  await api.login('user1@abc', 'user1dev');
  const fixture = await api.createAgentFixture('user1@abc', null, ['slim_sync']);
  console.log('fixture:', JSON.stringify(fixture));

  const reg = await api.registrationToken('user1@abc', fixture.instance_id);
  const start = await api.gameStartPayload('user1@abc', fixture.instance_id, reg.token);

  const browser = await chromium.launch();
  const context = await browser.newContext();
  await seedGameCookies(context, baseURL, start);
  const page = await context.newPage();
  await page.goto(`${baseURL}/portal/game`);
  await waitConnected(page);
  await openSystem(page, fixture.system.id);

  const bootState = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state;
    return {
      features: st.portal.features,
      isSignedIn: st.portal.isSignedIn,
      hasAccount: !!(st.portal.account && st.portal.account.id),
    };
  });
  console.log('bootState:', JSON.stringify(bootState));

  const { pickBuildCandidates, playerPush } = require('./helpers/game');

  const deck = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return {
      max_admirals: st.player.max_admirals,
      characters: (st.player.characters || []).map((c) => ({ id: c.id, type: c.type, status: c.status })),
      deck: (st.player.character_deck || []).map((d) => ({
        cooldown: d.cooldown,
        id: d.character && d.character.id,
        type: d.character && d.character.type,
        status: d.character && d.character.status,
        cost: d.character && d.character.credit_cost,
      })),
    };
  });
  console.log('deck:', JSON.stringify(deck, null, 1));

  const admiral = deck.deck.find((d) => d.type === 'admiral' && d.cooldown === null && d.status === 'in_deck');
  if (admiral) {
    const rawHire = await page.evaluate((id) => new Promise((resolve) => {
      document.querySelector('#app').__vue__.$socket.player
        .push('hire_character', { character: { id } })
        .receive('ok', (data) => resolve({ ok: true, data }))
        .receive('error', (err) => resolve({ ok: false, rawError: err }))
        .receive('timeout', () => resolve({ ok: false, rawError: 'TIMEOUT' }));
    }), admiral.id);
    console.log('hire result:', JSON.stringify(rawHire));
  } else {
    console.log('no eligible admiral in deck');
  }

  const dump = await page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const sys = st.selectedSystem;
    return {
      patents: st.player.patents,
      technology: st.player.technology && st.player.technology.value,
      patentSample: (st.data.patent || []).slice(0, 4),
      bodies: (sys.bodies || []).map((b) => ({
        uid: b.uid,
        type: b.type,
        tiles: (b.tiles || []).map((t) => ({
          id: t.id, type: t.type, key: t.building_key, bstatus: t.building_status, cstatus: t.construction_status,
        })),
        subBodies: (b.bodies || []).length,
      })),
    };
  });
  console.log(JSON.stringify(dump, null, 1).slice(0, 5000));

  const candidates = await pickBuildCandidates(page);
  console.log('candidates:', JSON.stringify(candidates, null, 1));

  if (candidates.length) {
    const cand = candidates[0];
    if (!cand.patentOwned) {
      console.log('purchasing patent', cand.patent,
        JSON.stringify(await playerPush(page, 'purchase_patent', { patent_key: cand.patent })));
    }
    console.log('ordering', cand.key,
      JSON.stringify(await playerPush(page, 'order_building', {
        system_id: fixture.system.id,
        production_data: {
          type: 'build', target_id: cand.body, tile_id: cand.tile, prod_key: cand.key, prod_level: 1,
        },
      })));
  }

  await api.finishInstance('admin@abc', fixture.instance_id);
  await browser.close();
  await req.dispose();
})().catch((e) => { console.error(e); process.exit(1); });
