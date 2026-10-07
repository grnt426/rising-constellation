// Agent training (docs/agent-training.md), through the real UI.
//
// The player's home system has a Delta Polytech and a level-2 Orb-INTEL
// (the fixture's `schools` option). The player:
//   - sees both schools in the system view, with their free seats, and
//     the seats each building gives on its card;
//   - recalls its Erased and sends it to the Orb-INTEL from a free seat
//     (deck panel, "Enrol"): the seat is taken, the fee is in the credit
//     income, the agent is on the roster as a student;
//   - lets the course run (speed cheat) and watches the ring around the
//     seated student, one segment per rewire: at the fifth the agent is
//     back in the deck by itself and the seat is free;
//   - moves skill points from the deck with the −/+ controls and confirms:
//     the skills and the rewires follow;
//   - cannot give the agent any duty while a rewire is left; discards the
//     rest from the card (the button asks twice) and then can;
//   - seats the same Erased in the Polytech, where it earns experience and
//     no rewires;
//   - queues its Navarch behind it from the place shown above the seat: the
//     Navarch stays in the deck, its card tells the wait and offers to leave
//     the queue, and it takes the seat the moment the Erased is recalled.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { Api } = require('../helpers/api');
const {
  seedGameCookies, waitConnected, openSystem, playerPush, setSpeedCheat, serverPlayer,
} = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// E2E_SHOTS=<dir> keeps a screenshot of each step (layout review).
const SHOTS = process.env.E2E_SHOTS;

let api;
let instanceId;
let home;
// seats of the Orb-INTEL: one per level (Flash buildings have one level)
let orbSeats;

async function shot(page, name) {
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

async function enterGame(page, context, baseURL) {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
}

// A school of the open system: 'polytech', or the agent type of a university.
const school = (page, key) => page.locator(`.school-box .school[data-school="${key}"]`);

// Seats taken and free, as the row shows them.
async function seats(page, key) {
  return {
    taken: await school(page, key).locator('.school-seat.is-taken').count(),
    free: await school(page, key).locator('.school-seats > .school-seat.is-empty').count(),
  };
}

function roster(page) {
  return page.evaluate(() => {
    const { player } = document.querySelector('#app').__vue__.$store.state.game;
    return {
      characters: player.characters.map((c) => ({
        id: c.id, type: c.type, status: c.status, level: c.level, training: c.training || null,
      })),
      deck: player.character_deck.map(({ character, cooldown, queue }) => ({
        id: character.id,
        type: character.type,
        skills: character.skills,
        specialization: character.specialization,
        rewires: character.reallocations || 0,
        resting: !!cooldown && cooldown.value !== 0,
        queue: queue || null,
      })),
      creditDetails: JSON.stringify(player.credit.details),
    };
  });
}

// The deck panel's card of one agent.
const deckCard = (page, name) => page.locator('.mp-container .card-container', { hasText: name });

async function waitRested(page, id) {
  await expect.poll(async () => {
    const entry = (await roster(page)).deck.find((c) => c.id === id);
    return entry ? entry.resting : null;
  }, { timeout: 120000 }).toBe(false);
}

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(
    PLAYER.email,
    { credit: 5000000, technology: 1000000, ideology: 1000000 },
    null, null, null, null,
    { destabilize: false, schools: true },
  );
  instanceId = fixture.instance_id;
  home = fixture.empire.home;
  orbSeats = fixture.empire.schools.buildings.find((b) => b.key === 'counterintelligence_open').level;
});

test.afterAll(async () => {
  if (api && instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('an Erased goes to university, comes back with neural rewires, its skills are reallocated, and a Navarch queues behind it', async ({ page, context, baseURL }) => {
  page.setDefaultTimeout(30000);
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error.message)));

  await enterGame(page, context, baseURL);
  await openSystem(page, home);

  const erased = (await roster(page)).characters.find((c) => c.type === 'spy' && c.status === 'on_board');
  expect(erased, 'the fixture places an Erased on board').toBeTruthy();
  const erasedName = (await serverPlayer(page)).characters.find((c) => c.id === erased.id).name;

  await test.step('the system shows its schools and their seats', async () => {
    expect(await seats(page, 'polytech')).toEqual({ taken: 0, free: 1 });
    expect(await seats(page, 'spy')).toEqual({ taken: 0, free: orbSeats });
    await expect(school(page, 'spy').locator('.school-seats > .school-seat.is-empty.is-clickable')).toHaveCount(orbSeats);

    // a school is its building's icon; the tooltip names it
    await school(page, 'spy').locator('.school-building').hover();
    await expect(page.locator('.tooltip .tooltip-inner', { hasText: 'Orb-INTEL' })).toBeVisible();
    await shot(page, '01-schools');
  });

  await test.step('the cards of both buildings say how many agents they seat', async () => {
    const card = page.locator('.system-building-card .card-container');
    const tiles = page.locator('.system-content-group .body-tiles .tile:has(.tile-level) .tile-icon');
    const seatsRow = card.locator('.complex-bonus', { hasText: /seats/i });

    // The card follows the hovered tile after a short hover delay, and its
    // stylesheet upper-cases the text: wait for the title, compare in lower case.
    const cardOf = async (name) => {
      for (let i = 0; i < await tiles.count(); i += 1) {
        await tiles.nth(i).hover();
        const shown = await expect(card.locator('.title-large')).toContainText(name, { ignoreCase: true, timeout: 1500 })
          .then(() => true, () => false);
        if (shown) return true;
      }
      return false;
    };

    expect(await cardOf('Delta Polytech')).toBe(true);
    await expect(seatsRow).toHaveText(/training seats\s*1/i);

    expect(await cardOf('Orb-INTEL')).toBe(true);
    await expect(seatsRow).toHaveText(new RegExp(`course seats, erased\\s*${orbSeats}`, 'i'));

    // a building that is no school says nothing about seats
    await tiles.first().hover();
    await expect(card.locator('.title-large')).not.toContainText('Orb-INTEL', { ignoreCase: true });
    await expect(seatsRow).toHaveCount(0);
    await shot(page, '01b-building-card');
    await page.mouse.move(1250, 780);
  });

  await test.step('recall the Erased: it rests in the deck before a new duty', async () => {
    expect((await playerPush(page, 'deactivate_character', { character_id: erased.id })).ok).toBe(true);
    await waitRested(page, erased.id);
  });

  await test.step('a free Orb-INTEL seat opens the deck on an Enrol button', async () => {
    await school(page, 'spy').locator('.school-seats > .school-seat.is-empty').first().click();
    await expect(deckCard(page, erasedName)).toBeVisible();
    await expect(deckCard(page, erasedName).locator('.card-action .button')).toHaveText('Enrol');
    await shot(page, '02-deck-enrol');
  });

  await test.step('enrol: the seat is taken and the fee is in the income', async () => {
    await deckCard(page, erasedName).locator('.card-action .button').click();

    await expect(school(page, 'spy').locator('.school-seat.is-taken')).toHaveCount(1);
    expect(await seats(page, 'spy')).toEqual({ taken: 1, free: orbSeats - 1 });

    const state = await roster(page);
    const student = state.characters.find((c) => c.id === erased.id);
    expect(student.status).toBe('student');
    expect(student.training.school).toBe('university');
    expect(state.creditDetails).toContain('character_tuition');

    // the ring around the student: one segment per rewire, none earned yet
    const ring = school(page, 'spy').locator('.school-seat.is-taken .seat-ring path');
    await expect(ring).toHaveCount(5);
    await expect(school(page, 'spy').locator('.seat-ring path.is-earned')).toHaveCount(0);
    await shot(page, '03-enrolled');
  });

  await test.step('the student card: where it stands, cut defence, Recall', async () => {
    await school(page, 'spy').locator('.school-seat.is-taken .round-icon').click();
    const card = page.locator('.opened-character .card-container');
    await expect(card.locator('.card-ribbon').first()).toContainText('Orb-INTEL');
    await expect(card.locator('.simple-bonus.is-cut')).toHaveCount(2);
    await expect(card.locator('.card-action .button')).toHaveText('Recall');
    await shot(page, '04-student-card');
    await page.evaluate(() => document.querySelector('#app').__vue__.$store.dispatch('game/closeCharacter'));
    await expect(card).toHaveCount(0);
  });

  await test.step('the ring fills as the course runs; the fifth rewire brings the agent home', async () => {
    // a rewire every few seconds: slow enough to see the ring fill
    expect((await setSpeedCheat(page, 10)).ok).toBe(true);

    await expect.poll(
      () => school(page, 'spy').locator('.seat-ring path.is-earned').count(),
      { timeout: 120000, intervals: [200] },
    ).toBeGreaterThan(0);
    await shot(page, '05-ring-filling');

    // nobody recalls it: the course ends in the deck
    await expect.poll(
      async () => (await roster(page)).deck.some((c) => c.id === erased.id),
      { timeout: 180000, intervals: [500] },
    ).toBe(true);

    expect((await setSpeedCheat(page, 1)).ok).toBe(true);

    const state = await roster(page);
    expect(state.deck.find((c) => c.id === erased.id).rewires).toBe(5);
    expect(state.characters.some((c) => c.id === erased.id)).toBe(false);
    expect(state.creditDetails).not.toContain('character_tuition');

    await expect(school(page, 'spy').locator('.school-seat.is-taken')).toHaveCount(0);
    await expect(school(page, 'spy').locator('.school-seats > .school-seat.is-empty')).toHaveCount(orbSeats);
    await shot(page, '05b-course-over');
  });

  await test.step('move a skill point with the card controls', async () => {
    // the deck from the navbar: no seat is being filled, so cards are in
    // their plain state
    await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      app.$store.commit('game/clearAssignment');
      app.$root.$emit('openBottomMiniPanel', 'character-deck');
    });

    const card = deckCard(page, erasedName);
    await expect(card.locator('.card-ribbon.is-reallocations')).toContainText('5 neural rewires');
    await shot(page, '06-deck-rewires');

    const before = (await roster(page)).deck.find((c) => c.id === erased.id);
    await card.locator('.card-ribbon.is-reallocations').click();
    await expect(card.locator('.skill-reallocation')).toHaveCount(6);

    // one point from a secondary skill to the main one; an agent whose
    // points are all in its main skill moves one out instead
    const { from, to } = await card.evaluate((el) => {
      const vm = el.__vue__;
      const main = vm.mainSkillIndex;
      const { skills } = vm.character;
      const secondary = skills.findIndex((value, i) => i !== main && value > 0);
      return secondary >= 0
        ? { from: secondary, to: main }
        : { from: main, to: skills.findIndex((value, i) => i !== main) };
    });
    const row = (i) => card.locator('.card-skill-block').nth(i).locator('.skill-reallocation button');
    await row(from).first().click();
    await row(to).last().click();
    await shot(page, '07-reallocating');

    const confirm = card.locator('.card-action .button');
    await expect(confirm).toHaveText('Confirm the new skills');
    await confirm.click();

    await expect.poll(async () => (await roster(page)).deck.find((c) => c.id === erased.id).rewires).toBe(4);
    const after = (await roster(page)).deck.find((c) => c.id === erased.id);
    expect(after.skills[from]).toBe(before.skills[from] - 1);
    expect(after.skills[to]).toBe(before.skills[to] + 1);
    await expect(card.locator('.skill-reallocation')).toHaveCount(0);
    await expect(card.locator('.card-ribbon.is-reallocations')).toContainText('4 neural rewires');

    await shot(page, '08-reallocated');
  });

  await test.step('no duty while a rewire is left: the card says so and the server refuses', async () => {
    await waitRested(page, erased.id);
    // the deck panel covers the list; the seat is clickable once it has closed
    await page.locator('.mp-container .mph-close-button').first().click();
    await school(page, 'polytech').locator('.school-seats > .school-seat.is-empty').first().click();

    const card = deckCard(page, erasedName);
    await expect(card.locator('.card-action .button')).toHaveText('Spend its neural rewires first', { ignoreCase: true });
    await shot(page, '08b-rewires-unspent');

    for (const [event, payload] of [
      ['enroll_character', { character_id: erased.id, school: 'polytech', system_id: home }],
      ['enroll_character', { character_id: erased.id, school: 'university', system_id: home }],
      ['activate_character', { character_id: erased.id, mode: 'governor', system_id: home }],
      ['activate_character', { character_id: erased.id, mode: 'on_board', system_id: home }],
    ]) {
      expect(await playerPush(page, event, payload)).toMatchObject({ ok: false, error: 'reallocations_unspent' });
    }

    // give the other four up, from the same card: the button asks twice
    const skillsBefore = (await roster(page)).deck.find((c) => c.id === erased.id).skills;
    await card.locator('.card-ribbon.is-reallocations').click();
    const button = card.locator('.card-action .button');
    await expect(button).toHaveText('Discard 4 rewires', { ignoreCase: true });
    await button.click();
    await expect(button).toHaveText('Are you sure? Discard', { ignoreCase: true });
    expect((await roster(page)).deck.find((c) => c.id === erased.id).rewires).toBe(4);
    await shot(page, '08c-discard-armed');
    await button.click();

    await expect.poll(async () => (await roster(page)).deck.find((c) => c.id === erased.id).rewires).toBe(0);
    await expect(card.locator('.card-ribbon.is-reallocations')).toHaveCount(0);
    await expect(card.locator('.card-action .button')).toHaveText('Enrol', { ignoreCase: true });
    expect((await roster(page)).deck.find((c) => c.id === erased.id).skills).toEqual(skillsBefore);
  });

  await test.step('the Polytech takes the same agent: experience, no rewires, no ring', async () => {
    await deckCard(page, erasedName).locator('.card-action .button').click();

    await expect(school(page, 'polytech').locator('.school-seat.is-taken')).toHaveCount(1);
    expect(await seats(page, 'polytech')).toEqual({ taken: 1, free: 0 });
    const student = (await roster(page)).characters.find((c) => c.id === erased.id);
    expect(student.training).toMatchObject({ school: 'polytech', phase: 'active' });
    expect((await roster(page)).creditDetails).not.toContain('character_tuition');
    await expect(school(page, 'polytech').locator('.seat-ring')).toHaveCount(0);
    await shot(page, '09-polytech');
  });

  const navarch = (await roster(page)).characters.find((c) => c.type === 'admiral' && c.status === 'on_board');
  expect(navarch, 'the fixture places a Navarch on board').toBeTruthy();
  const navarchName = (await serverPlayer(page)).characters.find((c) => c.id === navarch.id).name;
  const taken = school(page, 'polytech').locator('.school-seat.is-taken');

  await test.step('the place behind a seated student shows above it; the deck offers to join the queue', async () => {
    expect((await playerPush(page, 'deactivate_character', { character_id: navarch.id })).ok).toBe(true);
    await waitRested(page, navarch.id);

    // nobody waits yet: no dot on the seat, and the place to take on hover
    await expect(taken.locator('.queue-pip')).toHaveCount(0);
    await taken.locator('.round-icon').hover();
    const place = page.locator('.school-queue-popover .school-queue .queue-place');
    await expect(place).toBeVisible();
    await shot(page, '10-queue-place');
    await place.click();

    const card = deckCard(page, navarchName);
    await expect(card.locator('.card-action .button')).toHaveText('Join the queue', { ignoreCase: true });
    await shot(page, '11-deck-join-queue');
    await card.locator('.card-action .button').click();

    await expect.poll(async () => (await roster(page)).deck.find((c) => c.id === navarch.id).queue).toMatchObject({
      system_id: home, school: 'polytech', wait: null,
    });
  });

  await test.step('the queued agent stays in the deck: its seat shows it, its card tells the wait', async () => {
    // still a deck agent, and no duty for it
    expect((await roster(page)).characters.some((c) => c.id === navarch.id)).toBe(false);

    for (const [event, payload] of [
      ['activate_character', { character_id: navarch.id, mode: 'on_board', system_id: home }],
      ['enroll_character', { character_id: navarch.id, school: 'polytech', system_id: home }],
    ]) {
      expect(await playerPush(page, event, payload)).toMatchObject({ ok: false, error: 'character_queued' });
    }

    // a dot on the seat; the agent itself above it on hover
    await expect(taken.locator('.queue-pip')).toHaveCount(1);
    await taken.locator('.round-icon').hover();
    await expect(page.locator('.school-queue-popover .school-queue .queue-agent')).toBeVisible();
    await shot(page, '12-queue-shown');

    await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      app.$store.commit('game/clearAssignment');
      app.$root.$emit('openBottomMiniPanel', 'character-deck');
    });

    const card = deckCard(page, navarchName);
    // behind a Polytech student the wait has no end
    await expect(card.locator('.card-ribbon.is-queued')).toHaveText('Waiting for a seat', { ignoreCase: true });
    await expect(card.locator('.card-action .button').first()).toHaveText('Leave the queue', { ignoreCase: true });
    await expect(card.locator('.card-action .button.is-icon')).toHaveCount(1);
    await shot(page, '13-queued-card');

    // behind a university student it is the rest of that student's course:
    // the card's own wording of 38 hours, and of 25 minutes
    const wording = (ut) => card.evaluate((el, value) => {
      const vm = el.__vue__;
      const { seatWait } = vm.$options.computed;
      const fake = Object.create(vm, {
        queue: { value: { wait: { value } } },
        receivedAt: { value: Date.now() },
      });
      Object.defineProperty(fake, 'seatWait', { value: seatWait.call(fake) });
      return {
        text: vm.$options.computed.seatWaitText.call(fake),
        hint: vm.$options.computed.seatWaitHint.call(fake),
      };
    }, ut);

    const perHour = await page.evaluate(() => 3600000 / document.querySelector('#app').__vue__.$store.getters['game/tickToMilisecondFactor']);
    expect((await wording(38 * perHour)).text).toBe('38hrs to be seated');
    expect((await wording(38 * perHour)).hint).toMatch(/^Latest time to be seated: .*\d/);
    expect((await wording((25 / 60) * perHour)).text).toBe('25min to be seated');
  });

  await test.step('leave the queue from the card, join it again', async () => {
    const card = deckCard(page, navarchName);
    await card.locator('.card-action .button').first().click();

    await expect.poll(async () => (await roster(page)).deck.find((c) => c.id === navarch.id).queue).toBe(null);
    await expect(card.locator('.card-ribbon.is-queued')).toHaveCount(0);
    await page.locator('.mp-container .mph-close-button').first().click();
    await expect(taken.locator('.queue-pip')).toHaveCount(0);

    expect(await playerPush(page, 'queue_character', {
      character_id: navarch.id, school: 'polytech', system_id: home, behind: erased.id,
    })).toMatchObject({ ok: true });
    await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      app.$store.dispatch('game/reloadSystem', app.$socket);
    });
    await expect(taken.locator('.queue-pip')).toHaveCount(1);
  });

  await test.step('the student ahead is recalled: the queued agent takes the seat at once', async () => {
    expect((await playerPush(page, 'deactivate_character', { character_id: erased.id })).ok).toBe(true);

    await expect.poll(async () => {
      const student = (await roster(page)).characters.find((c) => c.id === navarch.id);
      return student ? student.status : null;
    }).toBe('student');

    const state = await roster(page);
    expect(state.deck.some((c) => c.id === navarch.id)).toBe(false);
    expect(state.deck.some((c) => c.id === erased.id)).toBe(true);

    await expect(taken).toHaveCount(1);
    await expect(taken.locator('.queue-pip')).toHaveCount(0);
    await taken.locator('.round-icon').click();
    await expect(page.locator('.opened-character .card-container .title-large')).toContainText(navarchName, { ignoreCase: true });
    await shot(page, '14-seated-from-queue');
  });

  expect(errors).toEqual([]);
});
