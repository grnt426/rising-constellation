// Armada end-to-end: form / join / break through the real client
// pipeline (socket push → Player.Agent → ArmadaImpl → {:update_armada}
// casts → player_player broadcast → store), plus the server-side rules
// a UI cannot bypass: the 3-Navarch cap, the dynamic-lead rule, the
// Deserter-stance ban, and attached transit (the lead moves, members
// ride with no motion state and arrive together).
//
// The fixture places 4 own navarchs in the starting system
// (own_admirals: 4) so the cap rejection is a live server answer, not
// a client-side guess. DOM assertions cover the owner-only visuals on
// the fan display (agent_fan_display beta): the member-count badge and
// the formation arc.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, openSystem, playerPush, setSpeedCheat,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// Roster snapshot of own admirals: [{id, system, status, armada}]
function ownAdmirals(page) {
  return page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    return (st.player.characters || [])
      .filter((c) => c.type === 'admiral' && c.status === 'on_board')
      .map((c) => ({
        id: c.id, system: c.system, action_status: c.action_status, armada: c.armada || null,
      }));
  });
}

// Server-truth armada map for one character (survives client staleness).
async function serverArmada(page, characterId) {
  const res = await playerPush(page, 'get_character', { character_id: characterId });
  if (!res.ok) throw new Error(`get_character failed: ${res.error}`);
  return res.data.character.armada || null;
}

test('armada: form, join, cap, lead rule, stance ban, transit, break', async ({ page, context, request, baseURL }) => {
  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 100000, technology: 500, ideology: 500 },
    ['agent_fan_display'],
    4,
  );
  const instanceId = fixture.instance_id;
  const homeSystemId = fixture.system.id;

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);

    await page.goto('/portal/game');
    await waitConnected(page);

    // Flash speed is still real time — compress travel for the transit leg.
    const cheat = await setSpeedCheat(page, 10);
    expect(cheat.ok, `set_speed failed: ${cheat.error}`).toBe(true);

    // ---- setup: four own navarchs at home, no armadas ----
    const admirals = await ownAdmirals(page);
    expect(admirals.length, 'fixture must place 4 own navarchs').toBe(4);
    expect(admirals.every((a) => a.system === homeSystemId)).toBe(true);
    expect(admirals.every((a) => a.armada === null)).toBe(true);
    const [a1, a2, a3, a4] = admirals.map((a) => a.id);

    // ---- form: two navarchs become a named armada ----
    const form = await playerPush(page, 'form_armada', {
      character_id: a1, other_character_id: a2,
    });
    expect(form.ok, `form_armada failed: ${form.error}`).toBe(true);

    await expect.poll(() => serverArmada(page, a1)).not.toBeNull();
    const formed = await serverArmada(page, a1);
    expect(formed.member_ids.slice().sort((x, y) => x - y)).toEqual([a1, a2].sort((x, y) => x - y));
    expect(typeof formed.name).toBe('string');
    expect(formed.name.length).toBeGreaterThan(0);
    expect(await serverArmada(page, a2)).toEqual(formed);

    // double-form is rejected — a1 already belongs to an armada
    const reform = await playerPush(page, 'form_armada', {
      character_id: a1, other_character_id: a3,
    });
    expect(reform.ok).toBe(false);
    expect(reform.error).toBe('armada_already_member');

    // ---- join: a third navarch; a fourth hits the cap ----
    const join = await playerPush(page, 'join_armada', {
      character_id: a3, armada_character_id: a1,
    });
    expect(join.ok, `join_armada failed: ${join.error}`).toBe(true);
    await expect.poll(async () => {
      const a = await serverArmada(page, a3);
      return a ? a.member_ids.length : 0;
    }).toBe(3);

    const overflow = await playerPush(page, 'join_armada', {
      character_id: a4, armada_character_id: a1,
    });
    expect(overflow.ok).toBe(false);
    expect(overflow.error, 'the proposal wants an explicit full-armada answer').toBe('armada_full');
    expect(await serverArmada(page, a4)).toBeNull();

    // ---- owner-only visuals on the fan display ----
    // roster must have caught up through the update_character casts
    await expect.poll(async () => {
      const roster = await ownAdmirals(page);
      return roster.filter((a) => a.armada && a.armada.member_ids.length === 3).length;
    }).toBe(3);

    await openSystem(page, homeSystemId);
    // 3 member-count badges on the inner-ring agent icons...
    await expect(page.locator('.agent-badge .armada', { hasText: '3' })).toHaveCount(3);
    // ...under one formation arc
    await expect(page.locator('.armada-links path')).toHaveCount(1);

    // ---- the Deserter-stance ban (test class 3, server truth) ----
    const flee = await playerPush(page, 'update_reaction', {
      character_id: a2, reaction: 'flee',
    });
    expect(flee.ok).toBe(false);
    expect(flee.error).toBe('armada_flee_stance_forbidden');
    // a non-member may still desert
    const soloFlee = await playerPush(page, 'update_reaction', {
      character_id: a4, reaction: 'flee',
    });
    expect(soloFlee.ok, `solo flee stance failed: ${soloFlee.error}`).toBe(true);

    // ---- attached transit + the lead rule (test class 4) ----
    // neighbor of home, from the galaxy edges the client renders
    // edges carry nested system objects: {s1: {id,...}, s2: {id,...}}
    const neighborId = await page.evaluate((home) => {
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

    // a1 enqueues the jump and becomes the lead...
    const move = await playerPush(page, 'add_character_actions', {
      character_id: a1,
      actions: [{ type: 'jump', data: { source: homeSystemId, target: neighborId } }],
    });
    expect(move.ok, `lead jump failed: ${move.error}`).toBe(true);

    // ...so a member's own enqueue is rejected while the armada moves
    const usurp = await playerPush(page, 'add_character_actions', {
      character_id: a2,
      actions: [{ type: 'jump', data: { source: homeSystemId, target: neighborId } }],
    });
    expect(usurp.ok).toBe(false);
    expect(usurp.error).toBe('armada_led_by_other');

    // the whole armada arrives together: all three at the neighbor,
    // idle, still members — members never carried motion state
    await expect.poll(async () => {
      const states = await Promise.all([a1, a2, a3].map(async (id) => {
        const res = await playerPush(page, 'get_character', { character_id: id });
        return res.ok ? res.data.character : null;
      }));
      if (states.some((c) => !c)) return 'unreachable';
      if (states.some((c) => c.system !== neighborId)) return 'in transit';
      if (states.some((c) => c.action_status !== 'idle')) return 'not idle';
      return 'arrived';
    }, { timeout: 180000, intervals: [3000] }).toBe('arrived');

    expect((await serverArmada(page, a2)).member_ids.length).toBe(3);

    // ---- break: detach one, then dissolve (test class 1) ----
    const breakOne = await playerPush(page, 'break_armada', { character_id: a3 });
    expect(breakOne.ok, `break_armada failed: ${breakOne.error}`).toBe(true);
    await expect.poll(() => serverArmada(page, a3)).toBeNull();
    expect((await serverArmada(page, a1)).member_ids.slice().sort((x, y) => x - y))
      .toEqual([a1, a2].sort((x, y) => x - y));

    const dissolve = await playerPush(page, 'break_armada', { character_id: a1 });
    expect(dissolve.ok, `dissolving break failed: ${dissolve.error}`).toBe(true);
    await expect.poll(() => serverArmada(page, a1)).toBeNull();
    expect(await serverArmada(page, a2)).toBeNull();
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});
