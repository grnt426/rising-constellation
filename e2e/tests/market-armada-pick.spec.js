// Player market, Post tab: a Navarch that belongs to an armada cannot be
// listed from the field (Instance.Player.Market refuses it with
// :character_in_armada — test/game/instance/player/market_armada_listing_test.exs).
// The picker says so before the form opens:
//   - an armada member's card is dimmed and carries the reason as a tooltip;
//   - clicking it toasts the reason and leaves the picker open;
//   - a Navarch outside the armada opens the offer form as before;
//   - the server gives the same answer to a client that skips the picker.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected, playerPush } = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// The picker's cards with what the test needs to tell them apart.
function pickerCards(page) {
  return page.evaluate(() => [...document.querySelectorAll('.mpc-characters-list .card-container')]
    .map((el) => ({
      id: el.__vue__.character.id,
      type: el.__vue__.character.type,
      unavailable: el.classList.contains('is-unavailable'),
      opacity: Number(getComputedStyle(el).opacity),
    })));
}

const cardOf = (page, id) => page.locator(`.mpc-characters-list .card-container[data-e2e-id="${id}"]`);

test('market: an armada member cannot be picked in the Post tab', async ({ page, context, request, baseURL }) => {
  const api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  // three own navarchs at home, the first two pre-formed as an armada
  const fixture = await api.createAgentFixture(PLAYER.email, null, null, 3, { own: [2] });
  const instanceId = fixture.instance_id;

  try {
    const reg = await api.registrationToken(PLAYER.email, instanceId);
    const payload = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
    await seedGameCookies(context, baseURL, payload);

    await page.goto('/portal/game');
    await waitConnected(page);

    const [members] = fixture.armadas.own;
    expect(members.length, 'fixture must pre-form a 2-navarch armada').toBe(2);

    const admirals = await page.evaluate(() => document.querySelector('#app').__vue__.$store.state.game
      .player.characters.filter((c) => c.type === 'admiral' && c.status === 'on_board')
      .map((c) => ({ id: c.id, armada: !!c.armada })));
    expect(admirals.length).toBe(3);
    const solo = admirals.find((a) => !a.armada).id;
    expect(admirals.filter((a) => a.armada).map((a) => a.id).sort()).toEqual(members.slice().sort());

    // ---- market → Post → Trade → agent on assignment ----
    await page.evaluate(() => { document.querySelector('#app').__vue__.$root.$emit('openTopMiniPanel', 'market'); });
    const tabIndex = await page.evaluate(() => document.querySelector('.mp-container').__vue__.tabs.indexOf('sell'));
    await page.locator('.mph-nav-item').nth(tabIndex).click();
    await page.locator('.mpc-market-category').last().locator('.mpc-offer-item').last().click();
    await expect(page.locator('.mpc-characters-list .card-container').first()).toBeVisible();

    // tag the cards so each can be clicked by agent id
    await page.evaluate(() => document.querySelectorAll('.mpc-characters-list .card-container')
      .forEach((el) => el.setAttribute('data-e2e-id', el.__vue__.character.id)));

    // ---- the armada's members are dimmed, everyone else is not ----
    const cards = await pickerCards(page);
    const navarchs = cards.filter((c) => c.type === 'admiral');
    expect(navarchs.map((c) => c.id).sort()).toEqual(admirals.map((a) => a.id).sort());
    expect(cards.filter((c) => c.unavailable).map((c) => c.id).sort()).toEqual(members.slice().sort());
    cards.forEach((c) => expect(c.opacity < 1, `card ${c.id} dimmed`).toBe(c.unavailable));

    // ---- clicking a member: the reason, and the picker stays ----
    const reason = await page.evaluate(() => document.querySelector('#app').__vue__
      .$t('toast.error.character_in_armada'));
    expect(reason).toContain('armada');

    await cardOf(page, members[0]).click();
    await expect(page.locator('.toasted', { hasText: reason })).toBeVisible();
    await expect(page.locator('.mpc-characters-list')).toBeVisible();
    await expect(page.locator('.mpc-character-input')).toHaveCount(0);

    // (a click hides the tooltip of the card under the pointer: read it
    // on the other member)
    await cardOf(page, members[1]).hover();
    await expect(page.locator('.tooltip', { hasText: reason })).toBeVisible();

    // ---- a Navarch outside the armada opens the form ----
    await cardOf(page, solo).click();
    await expect(page.locator('.mpc-character-input')).toBeVisible();
    await expect(page.locator('.mpc-characters-list')).toHaveCount(0);

    // ---- a client that skips the picker gets the same answer ----
    const offer = (characterId) => playerPush(page, 'create_offer', {
      mode: 'trade',
      type: 'board_character',
      data: { character_id: characterId },
      price: 0,
      allowed_players: [],
      allowed_factions: [],
    });

    const refused = await offer(members[1]);
    expect(refused.ok).toBe(false);
    expect(refused.error).toBe('character_in_armada');

    const listed = await offer(solo);
    expect(listed.ok, `listing the solo navarch failed: ${listed.error}`).toBe(true);
  } finally {
    await api.finishInstance(ADMIN.email, instanceId);
  }
});
