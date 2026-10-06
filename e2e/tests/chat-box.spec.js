// Faction chat, the box itself (what it says is chat-channels.spec.js):
//
//   - a box of a fixed size whatever it holds, oldest line at the top,
//     newest at the bottom right above the composer;
//   - it follows its latest line, unless the player scrolled back: then it
//     stays put and a pill says how many lines came in below;
//   - the hatched grip in its corner resizes it, within limits, and the
//     size survives a reload;
//   - the top bar's CHAT button closes and opens it; closed, the button
//     counts what was said meanwhile; open, it never wears a count;
//   - a message that mentions the player (`@Name`) is flagged on the
//     button open or closed, pulses the box once and lights its line,
//     until the player has seen it: the line in view under the pointer, a
//     click in the chat, or a click on the bubble (oldest first);
//   - typing `@` offers the faction's members; a name typed out is linked;
//   - with a system view open it rests as a strip of its latest lines and
//     opens to its full size under the pointer;
//   - on a phone it is a drawer of a fixed height, without a grip.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected, openSystem } = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

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

function say(page, message, channel = 'general') {
  return page.evaluate(({ message: m, channel: c }) => new Promise((resolve) => {
    document.querySelector('#app').__vue__.$socket.faction
      .push('push_chat_message', { message: m, channel: c })
      .receive('ok', () => resolve(true))
      .receive('error', () => resolve(false))
      .receive('timeout', () => resolve(false));
  }), { message, channel });
}

function messages(page) {
  return page.evaluate(() => JSON.parse(JSON.stringify(
    document.querySelector('#app').__vue__.$store.state.game.faction.chat,
  )));
}

// A line from somebody else in the faction, committed the way a faction
// broadcast brings it. The fixture has nobody else in the faction, and
// the server stamps the sender itself, so there is no saying it for
// real. It lasts until the next real broadcast: assert right after.
function hear(page, message, channel = 'general') {
  return page.evaluate(({ message: m, channel: c }) => {
    const { $store } = document.querySelector('#app').__vue__;
    const { faction } = $store.state.game;
    // Above every id handed out so far, here or by the server: the next
    // broadcast drops these lines, but the read marks they left stay.
    const id = faction.chat.reduce((max, line) => Math.max(max, line.id || 0), window.__e2eHeard || 0) + 1;
    window.__e2eHeard = id;

    $store.commit('game/update', {
      faction_faction: {
        ...faction,
        chat: [...faction.chat, {
          id, from: 'Ally', from_id: -1, message: m, channel: c, meta: {}, timestamp: Math.floor(Date.now() / 1000),
        }],
      },
    });

    return id;
  }, { message, channel });
}

const line = (page, id) => page.locator(`.chat-message[data-message-id="${id}"]`);

const rect = (locator) => locator.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height, bottom: r.bottom };
});

// How far the list is from showing its last line.
const fromLatest = (page) => page.locator('.chat-messages')
  .evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight);

async function drag(page, locator, dx, dy) {
  const from = await rect(locator);
  const x = from.x + from.w / 2;
  const y = from.y + from.h / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx / 2, y + dy / 2, { steps: 4 });
  await page.mouse.move(x + dx, y + dy, { steps: 4 });
  await page.mouse.up();
}

function shot(page, name, clip = { x: 0, y: 0, width: 760, height: 620 }) {
  return page.screenshot({ path: test.info().outputPath(`${name}.png`), clip });
}

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  const fixture = await api.createAgentFixture(PLAYER.email);
  instanceId = fixture.instance_id;
  homeSystemId = fixture.system.id;
});

test.afterAll(async () => {
  if (api && instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('the chat box: fixed size, latest line at the bottom, resizable, closable', async ({ page, context, baseURL }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error.message)));
  page.setDefaultTimeout(30000);
  await enterGame(page, context, baseURL, PLAYER.email);

  const box = page.locator('.chat-container');
  const list = page.locator('.chat-messages');
  const composer = page.locator('.chat-composer');
  const jump = page.locator('.chat-jump');
  const button = page.locator('.navbar.top .navbar-button-title.has-bubble');
  const bubble = button.locator('.navbar-button-bubble');

  await test.step('a box of a fixed size, oldest line first, composer at the bottom', async () => {
    await expect(box).toBeVisible();
    const before = await rect(box);
    expect(before).toMatchObject({ w: 300, h: 280 });
    await shot(page, '1-nearly-empty');

    for (let i = 1; i <= 30; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      expect(await say(page, `line ${i}`)).toBe(true);
    }
    await expect.poll(async () => (await messages(page)).filter((m) => m.message.startsWith('line ')).length)
      .toBe(30);
    await expect(page.locator('.chat-message', { hasText: 'line 30' })).toBeVisible();

    // thirty lines later, the same box
    expect(await rect(box)).toEqual(before);

    const ids = await page.$$eval('.chat-message[data-message-id]', (els) => els.map((el) => Number(el.dataset.messageId)));
    expect(ids.length).toBeGreaterThanOrEqual(30);
    expect(ids).toEqual([...ids].sort((a, b) => a - b));

    // the list above, the composer below, both inside the box
    const listBox = await rect(list);
    const composerBox = await rect(composer);
    expect(composerBox.y).toBeGreaterThanOrEqual(listBox.bottom);
    expect(composerBox.bottom).toBeLessThanOrEqual(before.bottom);

    // and it shows its latest line
    expect(await fromLatest(page)).toBeLessThan(2);
    await shot(page, '2-thirty-lines');

    // typed here, sent from here
    await composer.click();
    await page.keyboard.type('typed at the bottom');
    await page.keyboard.press('Enter');
    const typed = page.locator('.chat-message', { hasText: 'typed at the bottom' });
    await expect(typed).toBeVisible();
    expect((await rect(typed)).bottom).toBeLessThanOrEqual((await rect(list)).bottom);
    expect(await fromLatest(page)).toBeLessThan(2);
  });

  await test.step('scrolled back, it stays put and says what came in below', async () => {
    await list.evaluate((el) => { el.scrollTop = 0; });
    await expect.poll(() => fromLatest(page)).toBeGreaterThan(100);
    // let the scroll event land
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));

    await hear(page, 'anyone on the northern border?');
    await expect(jump).toBeVisible();
    await expect(jump).toContainText('1');
    expect(await list.evaluate((el) => el.scrollTop)).toBe(0);
    await shot(page, '3-scrolled-back');

    await jump.click();
    await expect(jump).toHaveCount(0);
    expect(await fromLatest(page)).toBeLessThan(2);
  });

  await test.step('the corner grip resizes it, within limits, and the size is kept', async () => {
    const grip = page.locator('.chat-grip');
    await expect(grip).toBeVisible();

    await drag(page, grip, 120, 100);
    expect(await rect(box)).toMatchObject({ w: 420, h: 380 });
    expect(await fromLatest(page)).toBeLessThan(2);
    await shot(page, '4-resized');

    // no smaller than what still reads as a chat
    await drag(page, grip, -600, -600);
    expect(await rect(box)).toMatchObject({ w: 260, h: 160 });
    await expect(composer).toBeVisible();
    expect(await fromLatest(page)).toBeLessThan(2);

    // no larger than the room between the bars
    await drag(page, grip, 0, 2000);
    const tall = await rect(box);
    expect(tall.h).toBe(900 - 2 * 54 - 10);

    await grip.dblclick();
    expect(await rect(box)).toMatchObject({ w: 300, h: 280 });

    await drag(page, grip, 80, 60);
    expect(await rect(box)).toMatchObject({ w: 380, h: 340 });

    await page.reload();
    await waitConnected(page);
    await expect(box).toBeVisible();
    expect(await rect(box)).toMatchObject({ w: 380, h: 340 });
    await expect.poll(() => fromLatest(page)).toBeLessThan(2);
  });

  await test.step('the CHAT button closes it, and counts what is said meanwhile', async () => {
    await expect(button).toHaveText(/chat/i);
    // between VICTORIES and HELP
    const labels = await page.$$eval('.navbar.top .navbar-left .navbar-button-title', (els) => els.map((el) => el.textContent.trim().toLowerCase()));
    expect(labels).toEqual(['victories', 'chat', 'help']);

    // open: what comes in is read on the spot, the button stays bare
    await hear(page, 'first');
    await expect(page.locator('.chat-message', { hasText: 'first' })).toBeVisible();
    await expect(bubble).toHaveCount(0);

    await button.click();
    await expect(box).toBeHidden();
    await expect(bubble).toHaveCount(0);

    await hear(page, 'second');
    await expect(bubble).toHaveText('1');
    // white, like every plain count in the game; the faction colour is for mentions
    await expect(bubble).toHaveCSS('background-color', 'rgb(230, 230, 230)');
    await hear(page, 'third', 'aid');
    await expect(bubble).toHaveText('2');
    await shot(page, '5-closed-two-unread');

    await button.click();
    await expect(box).toBeVisible();
    await expect(bubble).toHaveCount(0);
    await expect(page.locator('.chat-message', { hasText: 'third' })).toBeVisible();
    expect(await fromLatest(page)).toBeLessThan(2);

    // read by having been shown: closing again starts from zero
    await button.click();
    await expect(box).toBeHidden();
    await expect(bubble).toHaveCount(0);
    await button.click();
    await expect(box).toBeVisible();
  });

  await test.step('a mention is flagged open or closed, until the player has seen it', async () => {
    const me = await page.evaluate(() => {
      const { id, name } = document.querySelector('#app').__vue__.$store.state.game.player;
      return { id, name };
    });
    const at = `[[at:${me.id}|${me.name}]]`;
    const away = () => page.mouse.move(1200, 300);
    const backToTheTop = async () => {
      await list.evaluate((el) => { el.scrollTop = 0; });
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    };

    // Open, on the latest line, so it lands in view: flagged all the
    // same, since the pointer (the player's eyes) is on the map.
    await away();
    const first = await hear(page, `${at} hold the northern gate`);
    await expect(bubble).toHaveText('@');
    await expect(bubble).toHaveClass(/is-mention/);
    await expect(bubble).not.toHaveCSS('background-color', 'rgb(230, 230, 230)');
    await expect(box).toHaveClass(/is-mention-pulse/);
    await expect(line(page, first)).toHaveClass(/is-mention-new/);
    await expect(line(page, first).locator('.chat-ref-mention.is-me')).toHaveText(new RegExp(`@${me.name}`, 'i'));
    await shot(page, '5b-mention');
    // one beat, not a standing alarm
    await expect(box).not.toHaveClass(/is-mention-pulse/);
    await expect(bubble).toHaveText('@');

    // in view under the pointer: seen. The line stays marked, no longer lit.
    await box.hover();
    await expect(bubble).toHaveCount(0);
    await expect(line(page, first)).toHaveClass(/is-mention/);
    await expect(line(page, first)).not.toHaveClass(/is-mention-new/);

    // out of view, the pointer over the chat settles nothing…
    await away();
    await backToTheTop();
    const second = await hear(page, `${at} second call`);
    const third = await hear(page, `${at} third call`, 'aid');
    await expect(bubble).toHaveText('@2');
    await list.hover();
    await expect(bubble).toHaveText('@2');
    // …pulling the lines into view does
    await page.mouse.wheel(0, 20000);
    await expect(bubble).toHaveCount(0);
    await expect(line(page, second)).not.toHaveClass(/is-mention-new/);
    await expect(line(page, third)).not.toHaveClass(/is-mention-new/);

    // the bubble leads to them, oldest first, one click each
    await away();
    await backToTheTop();
    const fourth = await hear(page, `${at} fourth call`);
    const fifth = await hear(page, `${at} fifth call`);
    await expect(bubble).toHaveText('@2');
    await button.click();
    await expect(box).toBeVisible();
    await expect(line(page, fourth)).toHaveClass(/is-flash/);
    await expect(line(page, fourth)).toBeInViewport();
    await expect(bubble).toHaveText('@');
    await button.click();
    await expect(line(page, fifth)).toHaveClass(/is-flash/);
    await expect(bubble).toHaveCount(0);

    // nothing waiting: the button is the open/close toggle again
    await button.click();
    await expect(box).toBeHidden();

    // closed: the bubble is all there is, and it brings the chat back
    const sixth = await hear(page, `${at} sixth call`);
    await expect(bubble).toHaveText('@');
    await expect(bubble).toHaveClass(/is-pulsing/);
    await shot(page, '5c-mention-closed');
    await button.click();
    await expect(box).toBeVisible();
    await expect(line(page, sixth)).toHaveClass(/is-flash/);
    await expect(bubble).toHaveCount(0);

    // a click anywhere in the chat settles whatever is waiting
    await away();
    await backToTheTop();
    await hear(page, `${at} seventh call`);
    await hear(page, `${at} eighth call`);
    await expect(bubble).toHaveText('@2');
    await page.locator('.chat-tab').first().click();
    await expect(bubble).toHaveCount(0);

    // one's own mention of oneself is nobody calling
    await away();
    expect(await say(page, `${at} note to self`)).toBe(true);
    await expect(page.locator('.chat-message', { hasText: 'note to self' })).toBeVisible();
    await expect(bubble).toHaveCount(0);
  });

  await test.step('typing @ offers the faction members; a name typed out in full is linked too', async () => {
    // The fixture's faction has no one else in it: give the picker a
    // member to offer. Like `hear`, this lasts until the next broadcast.
    const enlist = () => page.evaluate(() => {
      const { $store } = document.querySelector('#app').__vue__;
      const { faction } = $store.state.game;
      $store.commit('game/update', {
        faction_faction: { ...faction, players: [...faction.players, { id: 987654, name: 'Ally Two' }] },
      });
    });
    const picker = page.locator('.chat-mention-picker');
    const lastSaid = async () => (await messages(page)).pop().message;

    await enlist();
    await composer.click();
    await page.keyboard.type('hey @al');
    await expect(picker.locator('.chat-mention-option')).toHaveText(['@Ally Two']);
    await shot(page, '5d-mention-picker');

    // Enter takes the pick; it does not send
    const before = (await messages(page)).length;
    await page.keyboard.press('Enter');
    await expect(picker).toHaveCount(0);
    await expect(composer.locator('.composer-chip-at')).toHaveText(/Ally Two/);
    expect((await messages(page)).length).toBe(before);

    await page.keyboard.type('to the gate');
    await page.keyboard.press('Enter');
    await expect.poll(lastSaid).toBe('hey [[at:987654|Ally Two]] to the gate');

    // typed out by hand, never picked
    await enlist();
    await composer.click();
    await page.keyboard.type('thanks @ally two!');
    await expect(picker).toHaveCount(0);
    await page.keyboard.press('Enter');
    await expect.poll(lastSaid).toBe('thanks [[at:987654|Ally Two]]!');
    await page.mouse.move(1200, 300);
  });

  await test.step('with a system open it rests as a strip, and opens under the pointer', async () => {
    const full = await rect(box);
    // Back to the mouse after the typing above: a system opened from the
    // keyboard shows its briefing, which lies over this corner.
    await page.locator('.chat-tab').first().click();
    await page.mouse.move(1200, 300);
    await openSystem(page, homeSystemId);

    await expect.poll(async () => (await rect(box)).h).toBe(98);
    // clear of the view's own panels
    expect((await rect(box)).bottom).toBeLessThanOrEqual((await rect(page.locator('.system-population'))).y);
    await expect(composer).toBeHidden();
    await expect(page.locator('.chat-tabs')).toBeHidden();
    await expect.poll(() => fromLatest(page)).toBeLessThan(2);
    await shot(page, '6-system-strip');

    await box.hover();
    await expect.poll(async () => (await rect(box)).h).toBe(full.h);
    await expect(composer).toBeVisible();
    await expect.poll(() => fromLatest(page)).toBeLessThan(2);
    // let the background settle before the picture
    await page.waitForTimeout(300);
    await shot(page, '7-system-open');

    await page.mouse.move(1200, 300);
    await expect.poll(async () => (await rect(box)).h).toBe(98);
  });

  await test.step('on a phone: a drawer of a fixed height, no grip, its own button', async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.locator('body')).toHaveClass(/is-mobile-ui/);

    await expect(page.locator('.chat-grip')).toHaveCount(0);
    await expect(button.locator('.svg-icon')).toBeVisible();

    // A tap, not a mouse click: under a mouse pointer the icon buttons
    // show their name in a tooltip, which then sits where the click goes.
    const tap = () => button.dispatchEvent('click');

    // back to the map: the open drawer lies over the system page's close
    // button, so put it away first
    await tap();
    await expect(box).toBeHidden();
    await page.locator('.system-close-button').click();
    await page.mouse.move(200, 600);
    await tap();

    await expect(box).toBeVisible();
    expect(await rect(box)).toMatchObject({ x: 0, w: 390, h: 340 });
    await shot(page, '8-phone', { x: 0, y: 0, width: 390, height: 500 });

    await tap();
    await expect(box).toBeHidden();
    await hear(page, 'on the phone');
    await expect(bubble).toHaveText('1');
    await shot(page, '9-phone-closed', { x: 0, y: 0, width: 390, height: 120 });
  });

  expect(errors, `page errors: ${errors.join(' | ')}`).toEqual([]);
});
