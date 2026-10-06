// Galaxy crosshair (portal Settings → Galaxy crosshair).
//
// The player redesigns the crosshair on the settings screen and the galaxy
// map of a match draws it:
//   - an account that never changed it has the original four black lines,
//     which no longer take a click meant for the map under them;
//   - lines, circle and dot combine, and the lines' two lengths change
//     from the keyboard;
//   - a faction quick pick, the hex field and the color wheel (mouse and
//     arrow keys) set the color;
//   - the crosshair lives on the account: the server has it, and a reload
//     starts with it;
//   - "Match my faction" draws it in the color of the faction played;
//   - "Remove the crosshair" leaves the map bare, "Reset to default" brings
//     the original back.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected } = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

// front/src/utils/factions.js, as the browser reports colors
const FACTION_RGB = {
  tetrarchy: 'rgb(63, 102, 223)',
  myrmezir: 'rgb(188, 36, 51)',
  cardan: 'rgb(142, 96, 191)',
  synelle: 'rgb(162, 205, 68)',
  ark: 'rgb(201, 161, 21)',
};

// [type, left, top, width, height], px from the center of the map: what the
// stylesheet drew before the crosshair could be changed
const ORIGINAL = [
  ['line', -100, -1, 80, 2],
  ['line', 20, -1, 80, 2],
  ['line', -1, -50, 2, 30],
  ['line', -1, 20, 2, 30],
];

// after the first round of changes below
const REDESIGNED = [
  ['line', -120, -1, 100, 2],
  ['line', 20, -1, 100, 2],
  ['line', -1, -40, 2, 20],
  ['line', -1, 20, 2, 20],
  ['circle', -12, -12, 24, 24],
  ['dot', -2, -2, 4, 4],
];

const MAP = '.map-cross';
const PREVIEW = '.crosshair-preview';

let api;
let instanceId;
let settingsBefore;

// ---- helpers ----------------------------------------------------------

// What is drawn inside `root`: every mark's box around the center, and the
// color they share.
function drawn(page, root) {
  return page.evaluate((selector) => {
    const holder = document.querySelector(`${selector} .crosshair-marks`);
    const center = holder.getBoundingClientRect();

    return {
      marks: [...holder.querySelectorAll('.crosshair-mark')].map((mark) => {
        const box = mark.getBoundingClientRect();
        const type = ['line', 'circle', 'dot'].find((t) => mark.classList.contains(`is-${t}`));
        return [type, box.left - center.left, box.top - center.top, box.width, box.height];
      }),
      color: getComputedStyle(holder).color,
    };
  }, root);
}

async function savedCrosshair() {
  return (await api.accountSettings(PLAYER.email)).crosshair;
}

const slider = (page, size) => page.locator(`.vue-slider-dot[aria-labelledby="crosshair-${size}"]`);

async function nudge(page, size, key, times) {
  await slider(page, size).focus();
  for (let i = 0; i < times; i += 1) await page.keyboard.press(key);
}

// { hue, saturation } as the wheel tells a screen reader
async function wheel(page) {
  const text = await page.locator('.color-wheel-disc').getAttribute('aria-valuetext');
  const [, hue, saturation] = text.match(/(\d+)°\D+(\d+)%/);
  return { hue: Number(hue), saturation: Number(saturation) };
}

async function openSettings(page) {
  await page.goto('/portal/settings/crosshair');
  await expect(page.locator(PREVIEW)).toBeVisible();
}

async function openGame(page) {
  await page.goto('/portal/game');
  await waitConnected(page);
  await expect(page.locator(`${MAP} .crosshair-marks`)).toBeAttached();
}

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  // an account that never changed its crosshair, whatever an earlier run left
  settingsBefore = await api.accountSettings(PLAYER.email);
  const { crosshair, ...untouched } = settingsBefore;
  await api.saveAccountSettings(PLAYER.email, untouched);

  const fixture = await api.createAgentFixture(PLAYER.email);
  instanceId = fixture.instance_id;
});

test.afterAll(async () => {
  if (!api) return;
  if (settingsBefore) {
    const now = await api.accountSettings(PLAYER.email);
    await api.saveAccountSettings(PLAYER.email, { ...now, crosshair: settingsBefore.crosshair || {} });
  }
  if (instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('the crosshair is redesigned in the settings and the galaxy map draws it', async ({ page, context, baseURL }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error.message)));

  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);

  await test.step('an untouched account has the original crosshair, and the map under it stays clickable', async () => {
    await openGame(page);
    expect(await drawn(page, MAP)).toEqual({ marks: ORIGINAL, color: 'rgb(0, 0, 0)' });

    // on the right-hand line, 60px from the center: the map, not the mark
    const under = await page.evaluate((selector) => {
      const { left, top } = document.querySelector(selector).getBoundingClientRect();
      return document.elementFromPoint(left + 60, top).tagName;
    }, MAP);
    expect(under).toBe('CANVAS');
  });

  await test.step('marks combine and the lines change length', async () => {
    await openSettings(page);
    expect(await drawn(page, PREVIEW)).toEqual({ marks: ORIGINAL, color: 'rgb(0, 0, 0)' });
    await expect(page.locator('.crosshair-note')).toHaveText(/actual size/i);

    await page.locator('label[for="crosshair-circle"]').click();
    await page.locator('label[for="crosshair-dot"]').click();

    await nudge(page, 'width', 'ArrowRight', 10);
    await expect(page.locator('#crosshair-width strong')).toHaveText(/^100 px$/i);
    await nudge(page, 'height', 'ArrowLeft', 5);
    await expect(page.locator('#crosshair-height strong')).toHaveText(/^20 px$/i);

    expect((await drawn(page, PREVIEW)).marks).toEqual(REDESIGNED);
  });

  await test.step('a faction quick pick, the hex field and the wheel set the color', async () => {
    const hex = page.locator('#crosshair-hex');
    const disc = page.locator('.color-wheel-disc');

    await page.getByRole('button', { name: 'Myrmezir' }).click();
    await expect(hex).toHaveValue('#bc2433');
    await expect(page.getByRole('button', { name: 'Myrmezir' })).toHaveAttribute('aria-pressed', 'true');
    expect((await drawn(page, PREVIEW)).color).toBe(FACTION_RGB.myrmezir);

    await hex.fill('#FFF');
    expect((await drawn(page, PREVIEW)).color).toBe('rgb(255, 255, 255)');
    await expect(page.getByRole('button', { name: 'Myrmezir' })).toHaveAttribute('aria-pressed', 'false');

    // right of the center, 80% of the way out: a quarter turn of hue
    const box = await disc.boundingBox();
    await disc.click({ position: { x: box.width * 0.9, y: box.height / 2 } });
    expect(await wheel(page)).toEqual({ hue: 90, saturation: 80 });
    await expect(hex).toHaveValue('#99ff33');
    expect((await drawn(page, PREVIEW)).color).toBe('rgb(153, 255, 51)');

    // and from the keyboard
    await disc.focus();
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowDown');
    expect(await wheel(page)).toEqual({ hue: 95, saturation: 75 });

    // back to a known color for what follows
    await page.getByRole('button', { name: 'A.R.K.' }).click();
    await expect(hex).toHaveValue('#c9a115');
  });

  await test.step('the crosshair is saved on the account and survives a reload', async () => {
    await expect.poll(savedCrosshair).toEqual({
      cross: true,
      circle: true,
      dot: true,
      color: '#c9a115',
      match_faction: false,
      width: 100,
      height: 20,
      circle_size: 24,
      dot_size: 4,
    });

    await page.reload();
    await expect(page.locator(PREVIEW)).toBeVisible();
    expect(await drawn(page, PREVIEW)).toEqual({ marks: REDESIGNED, color: FACTION_RGB.ark });
    await expect(page.locator('#crosshair-hex')).toHaveValue('#c9a115');

    await openGame(page);
    expect(await drawn(page, MAP)).toEqual({ marks: REDESIGNED, color: FACTION_RGB.ark });
  });

  await test.step('"Match my faction" draws it in the color of the faction played', async () => {
    await openSettings(page);
    await page.locator('label[for="crosshair-match-faction"]').click();

    // no match here: the preview borrows a faction, the first one to start
    await expect(page.locator('.color-wheel-disc')).toHaveCount(0);
    expect((await drawn(page, PREVIEW)).color).toBe(FACTION_RGB.tetrarchy);
    await page.getByRole('button', { name: 'Cardan' }).click();
    expect((await drawn(page, PREVIEW)).color).toBe(FACTION_RGB.cardan);

    // the chosen color is kept for the day the box is unticked
    await expect.poll(savedCrosshair).toMatchObject({ match_faction: true, color: '#c9a115' });

    await openGame(page);
    const faction = await page.evaluate(
      () => document.querySelector('#app').__vue__.$store.state.game.playerFaction,
    );
    expect(Object.keys(FACTION_RGB)).toContain(faction);
    expect(await drawn(page, MAP)).toEqual({ marks: REDESIGNED, color: FACTION_RGB[faction] });
  });

  await test.step('"Remove the crosshair" leaves the map bare', async () => {
    await openSettings(page);
    const remove = page.getByRole('button', { name: 'Remove the crosshair' });

    await remove.click();
    expect((await drawn(page, PREVIEW)).marks).toEqual([]);
    await expect(page.locator('.crosshair-note')).toHaveText(/no crosshair/i);
    await expect(remove).toHaveAttribute('aria-disabled', 'true');
    await expect(page.locator('.crosshair-mark-option .vue-slider')).toHaveCount(0);
    await expect.poll(savedCrosshair).toMatchObject({ cross: false, circle: false, dot: false, width: 100 });

    await openGame(page);
    expect((await drawn(page, MAP)).marks).toEqual([]);
  });

  await test.step('"Reset to default" brings the original back', async () => {
    await openSettings(page);
    const reset = page.getByRole('button', { name: 'Reset to default' });

    await reset.click();
    expect(await drawn(page, PREVIEW)).toEqual({ marks: ORIGINAL, color: 'rgb(0, 0, 0)' });
    await expect(reset).toHaveAttribute('aria-disabled', 'true');
    await expect(page.locator('#crosshair-match-faction')).not.toBeChecked();
    await expect.poll(savedCrosshair).toEqual({
      cross: true,
      circle: false,
      dot: false,
      color: '#000000',
      match_faction: false,
      width: 80,
      height: 30,
      circle_size: 24,
      dot_size: 4,
    });
  });

  expect(errors).toEqual([]);
});
