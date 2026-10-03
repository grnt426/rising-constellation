// Rebindable hotkeys (Help drawer → Keyboard shortcuts).
//
// The player changes shortcuts with real key presses and the game obeys
// them at once:
//   - a default key works until it is replaced, then only the new key does;
//   - while a row waits for its key, nothing pressed reaches the game
//     (binding A to another action must not open the operations panel),
//     and a key held past the capture does not fire its new shortcut;
//   - taking a key another action uses leaves that action without one and
//     says so; Esc backs out without opening the settings;
//   - combinations with modifiers work;
//   - bindings live on the account: the server has them, and a reload
//     (any game, any mode) starts with them;
//   - "Remove", "Default" and "Reset all" undo it.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies, waitConnected } = require('../helpers/game');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const ADMIN = { email: 'admin@abc', password: 'admindev' };

let api;
let instanceId;
let settingsBefore;

// ---- helpers ----------------------------------------------------------

// Game.vue's own state: which drawer is open, and the settings overlay.
function gameState(page) {
  return page.evaluate(() => {
    const game = document.querySelector('.game-context').__vue__;
    return { panel: game.somePanelIsOpen ? game.activePanel.name : null, settings: game.isSettingsOpen };
  });
}

const openPanel = async (page) => (await gameState(page)).panel;

function savedOverrides(page) {
  return page.evaluate(() => {
    const { hotkeys } = document.querySelector('#app').__vue__.$store.state.portal.settings;
    return JSON.parse(JSON.stringify(hotkeys));
  });
}

const row = (page, id) => page.locator(`.help-hotkeys-table tr[data-hotkey="${id}"]`);
const binding = (page, id) => row(page, id).locator('.help-hotkeys-binding');

// "Ctrl + Shift + K" as the row shows it
async function shown(page, id) {
  return (await binding(page, id).innerText()).replace(/\s+/g, ' ').trim().toUpperCase();
}

async function startCapture(page, id) {
  await binding(page, id).click();
  await expect(row(page, id)).toHaveClass(/is-capturing/);
}

async function openShortcutsTab(page) {
  if ((await openPanel(page)) !== 'help') await page.keyboard.press('h');
  await expect.poll(() => openPanel(page)).toBe('help');
  await page.locator('.panel-navbar button[data-help-tab="hotkeys"]').click();
  await expect(row(page, 'empire')).toBeVisible();
}

function toasts(page) {
  return page.$$eval('.toasted', (els) => els.map((el) => el.textContent.trim()));
}

async function enterGame(page, context, baseURL) {
  const reg = await api.registrationToken(PLAYER.email, instanceId);
  const start = await api.gameStartPayload(PLAYER.email, instanceId, reg.token);
  await seedGameCookies(context, baseURL, start);
  await page.goto('/portal/game');
  await waitConnected(page);
}

// ---- world ------------------------------------------------------------

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext();
  api = new Api(request, baseURL);
  await api.login(ADMIN.email, ADMIN.password);
  await api.login(PLAYER.email, PLAYER.password);

  // start from the defaults, whatever an earlier run left on the account
  settingsBefore = await api.accountSettings(PLAYER.email);
  await api.saveAccountSettings(PLAYER.email, { ...settingsBefore, hotkeys: {} });

  const fixture = await api.createAgentFixture(PLAYER.email);
  instanceId = fixture.instance_id;
});

test.afterAll(async () => {
  if (!api) return;
  if (settingsBefore) {
    const now = await api.accountSettings(PLAYER.email);
    await api.saveAccountSettings(PLAYER.email, { ...now, hotkeys: settingsBefore.hotkeys || {} });
  }
  if (instanceId) await api.finishInstance(ADMIN.email, instanceId);
});

test('hotkeys are rebound from the help drawer and persist on the account', async ({ page, context, baseURL }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error.message)));
  await enterGame(page, context, baseURL);

  await test.step('defaults: S toggles the empire drawer, the tab lists every shortcut', async () => {
    await page.keyboard.press('s');
    await expect.poll(() => openPanel(page)).toBe('empire');
    await page.keyboard.press('s');
    await expect.poll(() => openPanel(page)).toBe(null);

    await openShortcutsTab(page);
    expect(await shown(page, 'empire')).toBe('S');
    expect(await shown(page, 'settings')).toBe('ESC');
    expect(await shown(page, 'create_group_3')).toBe('CTRL + 3');
    await expect(page.locator('.help-hotkeys-table tr[data-hotkey]')).toHaveCount(36);
    await expect(page.locator('.help-hotkeys-table tr.is-modified')).toHaveCount(0);
    expect(await savedOverrides(page)).toEqual({});
  });

  await test.step('empire → G: the new key works, the old one is dead', async () => {
    await startCapture(page, 'empire');
    await page.keyboard.press('g');
    await expect(row(page, 'empire')).not.toHaveClass(/is-capturing/);
    expect(await shown(page, 'empire')).toBe('G');
    await expect(row(page, 'empire')).toHaveClass(/is-modified/);
    expect(await savedOverrides(page)).toEqual({ empire: ['g'] });
    // the key went to the capture, not to the game
    expect(await openPanel(page)).toBe('help');

    await page.keyboard.press('g');
    await expect.poll(() => openPanel(page)).toBe('empire');
    await page.keyboard.press('s');
    await page.waitForTimeout(600);
    expect(await openPanel(page)).toBe('empire');
    await page.keyboard.press('g');
    await expect.poll(() => openPanel(page)).toBe(null);

    await expect.poll(async () => (await api.accountSettings(PLAYER.email)).hotkeys).toEqual({ empire: ['g'] });
  });

  await test.step('ranking → A takes the key from operations, and says so', async () => {
    await openShortcutsTab(page);
    await startCapture(page, 'ranking');
    await page.keyboard.press('a');
    expect(await shown(page, 'ranking')).toBe('A');
    await expect(row(page, 'operations')).toHaveClass(/is-unbound/);
    // A was captured: it neither opened operations nor closed the help drawer
    expect(await openPanel(page)).toBe('help');
    expect(await savedOverrides(page)).toEqual({ empire: ['g'], operations: [], ranking: ['a'] });

    const operations = await row(page, 'operations').locator('td').innerText();
    await expect.poll(() => toasts(page)).toContainEqual(expect.stringContaining(operations.trim()));

    await page.keyboard.press('a');
    await expect.poll(() => openPanel(page)).toBe('ranking');
    await page.keyboard.press('a');
    await expect.poll(() => openPanel(page)).toBe(null);
  });

  await test.step('Esc backs out of a capture without opening the settings', async () => {
    await openShortcutsTab(page);
    await startCapture(page, 'faction');
    await page.keyboard.press('Escape');
    await expect(row(page, 'faction')).not.toHaveClass(/is-capturing/);
    expect(await shown(page, 'faction')).toBe('O');
    expect(await gameState(page)).toEqual({ panel: 'help', settings: false });

    // a click elsewhere backs out too
    await startCapture(page, 'faction');
    await page.locator('.help-hotkeys-intro').click();
    await expect(row(page, 'faction')).not.toHaveClass(/is-capturing/);

    // a modifier alone is not a shortcut: the row keeps waiting
    await startCapture(page, 'faction');
    await page.keyboard.press('Shift');
    await expect(row(page, 'faction')).toHaveClass(/is-capturing/);
    await page.keyboard.press('Escape');
  });

  await test.step('a combination: victory → Ctrl + Shift + K', async () => {
    await startCapture(page, 'victory');
    await page.keyboard.press('Control+Shift+K');
    expect(await shown(page, 'victory')).toBe('CTRL + SHIFT + K');
    expect((await savedOverrides(page)).victory).toEqual(['ctrl', 'shift', 'k']);
  });

  await test.step('a key held past the capture does not fire its new shortcut', async () => {
    await startCapture(page, 'help');
    await page.keyboard.down('j');
    await page.keyboard.down('j'); // auto-repeat
    await page.keyboard.down('j');
    await page.keyboard.up('j');
    expect(await shown(page, 'help')).toBe('J');
    await page.waitForTimeout(600);
    expect(await openPanel(page)).toBe('help');

    await page.keyboard.press('j');
    await expect.poll(() => openPanel(page)).toBe(null);
    await page.keyboard.press('h');
    await page.waitForTimeout(600);
    expect(await openPanel(page)).toBe(null);
    await page.keyboard.press('j');
    await expect.poll(() => openPanel(page)).toBe('help');
  });

  await test.step('labels that name a key follow the binding', async () => {
    const hint = (id) => page.evaluate(
      (action) => document.querySelector('#app').__vue__.$store.getters['portal/hotkeyHint'](action),
      id,
    );
    expect(await hint('ruler')).toBe(' (Z)');
    expect(await hint('victory')).toBe(' (Ctrl + Shift + K)');
    expect(await hint('operations')).toBe('');
  });

  const expected = {
    empire: ['g'], operations: [], ranking: ['a'], victory: ['ctrl', 'shift', 'k'], help: ['j'],
  };

  await test.step('the account has them: a reload starts with the same shortcuts', async () => {
    await expect.poll(async () => (await api.accountSettings(PLAYER.email)).hotkeys).toEqual(expected);

    await page.reload();
    await waitConnected(page);
    expect(await savedOverrides(page)).toEqual(expected);

    await page.keyboard.press('g');
    await expect.poll(() => openPanel(page)).toBe('empire');
    await page.keyboard.press('g');
    await expect.poll(() => openPanel(page)).toBe(null);

    await page.keyboard.press('j');
    await expect.poll(() => openPanel(page)).toBe('help');
    await page.locator('.panel-navbar button[data-help-tab="hotkeys"]').click();
    expect(await shown(page, 'empire')).toBe('G');
    expect(await shown(page, 'victory')).toBe('CTRL + SHIFT + K');
    await expect(row(page, 'operations')).toHaveClass(/is-unbound/);
    await expect(page.locator('.help-hotkeys-table tr.is-modified')).toHaveCount(5);
  });

  await test.step('Remove, Default and Reset all', async () => {
    await startCapture(page, 'center_character');
    await row(page, 'center_character').locator('.help-hotkeys-action').nth(1).click();
    await expect(row(page, 'center_character')).toHaveClass(/is-unbound/);
    expect((await savedOverrides(page)).center_character).toEqual([]);

    // S is free again (empire moved to G): operations can take it…
    await startCapture(page, 'operations');
    await page.keyboard.press('s');
    expect(await shown(page, 'operations')).toBe('S');
    // …and giving empire its default back takes it from operations
    await startCapture(page, 'empire');
    await row(page, 'empire').locator('.help-hotkeys-action').nth(0).click();
    expect(await shown(page, 'empire')).toBe('S');
    await expect(row(page, 'empire')).not.toHaveClass(/is-modified/);
    await expect(row(page, 'operations')).toHaveClass(/is-unbound/);
    expect((await savedOverrides(page)).empire).toBeUndefined();

    const reset = page.locator('.help-hotkeys-footer .help-hotkeys-action');
    await reset.click();
    // one click only arms it
    expect(Object.keys(await savedOverrides(page)).length).toBeGreaterThan(0);
    await reset.click();
    expect(await savedOverrides(page)).toEqual({});
    await expect(page.locator('.help-hotkeys-table tr.is-modified')).toHaveCount(0);
    await expect(reset).toBeDisabled();
    await expect.poll(async () => (await api.accountSettings(PLAYER.email)).hotkeys).toEqual({});

    await page.keyboard.press('h');
    await expect.poll(() => openPanel(page)).toBe(null);
    await page.keyboard.press('a');
    await expect.poll(() => openPanel(page)).toBe('operations');
  });

  expect(errors).toEqual([]);
});
