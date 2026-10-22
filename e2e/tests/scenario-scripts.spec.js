// Scenario scripts saved to the account, published, and attached to Forge
// scenarios (docs/scenario-scripting.md, "Scripts in matches").
//
// 1. The workshop saves the open script to the account, publishes it and
//    opens it again from the Scripts tab.
// 2. The Forge scenario editor attaches a saved script, checks it against
//    the map as it is picked (a script written for five factions on a
//    two-faction map warns), saves anyway, and the scenario list marks the
//    scenario as scripted.
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };

async function api(page, baseURL) {
  const a = new Api(page.request, baseURL);
  await a.login(PLAYER.email, PLAYER.password);
  return a;
}

async function signIn(page, baseURL) {
  const a = await api(page, baseURL);
  const url = new URL(baseURL);
  await page.context().addCookies([{
    name: 'user_token', value: a.tokens.get(PLAYER.email), domain: url.hostname, path: '/',
  }]);
  return a;
}

// An account keeps ten scripts: start each test from none.
async function clearScripts(page, a) {
  const headers = a.authHeaders(PLAYER.email);
  const res = await page.request.get('/api/edict/scripts', { headers });
  const { scripts } = await res.json();
  await Promise.all(scripts.map((s) => page.request.delete(`/api/edict/scripts/${s.id}`, { headers })));
}

async function openWorkshop(page) {
  await page.goto('/portal/scenario-workshop');
  await expect(page.locator('.wk-node').first()).toBeVisible({ timeout: 60000 });
  const end = page.locator('.wk-tour-card button', { hasText: 'End the tour' });
  await end.waitFor({ timeout: 15000 });
  await end.click();
}

test('the workshop saves a script to the account, publishes it and opens it again', async ({ page, baseURL }) => {
  const a = await signIn(page, baseURL);
  await clearScripts(page, a);
  page.on('dialog', (d) => d.accept());

  await openWorkshop(page);
  const name = (await page.locator('.wk-scenario-name').textContent()).trim();

  await page.locator('.wk-tabs button', { hasText: 'Scripts' }).click();
  const panel = page.locator('.wk-account');
  await expect(panel).toContainText("This script isn't saved to your account");
  await panel.locator('[data-test="account-save-new"]').click();
  await expect(page.locator('.toasted').last()).toContainText(`Saved "${name}" to your scripts`, { timeout: 10000 });
  await expect(panel.locator('.wk-account-current')).toContainText('Saved to your account');
  await expect(panel).toContainText('My scripts (1 of 10)');

  // what others see is what was saved: publishing waits for unsaved changes
  await panel.locator('[data-test="account-publish"]').click();
  await expect(page.locator('.toasted').last()).toContainText(`Published "${name}"`, { timeout: 10000 });
  await expect(panel.locator('.wk-account-current .wk-account-tag')).toHaveText('Published');
  await expect(panel.locator('section').nth(2)).toContainText(name);

  // a new script, then the saved one again from the list
  await page.locator('.wk-new select').selectOption('__blank');
  await expect(panel).toContainText("This script isn't saved to your account");
  await panel.locator('section').nth(1).locator('button', { hasText: 'Open' }).first().click();
  await expect(page.locator('.wk-scenario-name')).toHaveText(name, { timeout: 10000 });
  await expect(panel.locator('.wk-account-current')).toContainText('Saved to your account');

  await panel.locator('[data-test="account-unpublish"]').click();
  await expect(panel.locator('.wk-account-current .wk-account-tag')).toHaveText('Private', { timeout: 10000 });
});

test('the Forge editor attaches a script, warns when it does not suit the map, and the list marks it', async ({ page, baseURL }) => {
  const a = await signIn(page, baseURL);
  const headers = a.authHeaders(PLAYER.email);
  await clearScripts(page, a);

  // a script written for five factions
  const script = await (await page.request.post('/api/edict/scripts', {
    headers,
    data: { source: 'setup {\n  name = "Five Houses"\n  factions = 5\n}\n\nscore player.credit\n' },
  })).json();
  expect(script.script.name).toBe('Five Houses');

  // a scenario of the player's own, copied from a published two-faction one
  const list = await (await page.request.get('/api/scenarios', { headers, params: { page_size: 50 } })).json();
  const pick = list.find((s) => (s.game_metadata.factions || []).length === 2 && s.game_metadata.game_mode_type !== 'wave');
  expect(pick).toBeTruthy();
  const full = await (await page.request.get(`/api/scenarios/${pick.id}`, { headers })).json();
  const title = `Scripted e2e ${Date.now()}`;
  const created = await (await page.request.post('/api/scenarios', {
    headers,
    data: {
      scenario: {
        game_data: { ...full.game_data, scripts: [] },
        game_metadata: { ...full.game_metadata, name: title },
      },
    },
  })).json();

  try {
    await page.goto(`/portal/create/scenario/edit/${created.id}`);
    const section = page.locator('.scenario-scripts');
    await expect(section).toContainText('No scripts attached', { timeout: 30000 });

    await section.locator('button', { hasText: 'Attach a script' }).click();
    const choice = section.locator('.scenario-scripts-choices li', { hasText: 'Five Houses' });
    await choice.locator('button', { hasText: 'Attach' }).click();

    // checked against the map as it is picked
    const attached = section.locator('.scenario-script', { hasText: 'Five Houses' });
    await expect(attached.locator('.scenario-script-problems')).toContainText('written for 5 factions', { timeout: 15000 });
    await expect(attached.locator('.scenario-script-problems')).toContainText('this map has 2');

    // a warning doesn't stop the save
    await page.locator('button', { hasText: 'Save changes' }).click();
    await expect(page.locator('.toasted').last()).toContainText('Saved, with a warning about its scripts on this map', { timeout: 15000 });
    await expect(page).toHaveURL(/\/create\/scenarios/);

    // the scenario now carries a frozen copy, and lists mark it
    const saved = await (await page.request.get(`/api/scenarios/${created.id}`, { headers })).json();
    expect(saved.game_data.scripts.map((s) => s.name)).toEqual(['Five Houses']);
    expect(saved.game_metadata.scripted).toBe(true);

    await page.goto(`/portal/create/scenario/view/${saved.share_token}`);
    await expect(page.locator('.forge-detail-head .scripted-badge')).toBeVisible({ timeout: 30000 });
    await expect(page.locator('.forge-detail-scripts')).toContainText('Five Houses');
    await page.locator('.forge-detail-scripts summary').click();
    await expect(page.locator('.forge-script-source')).toContainText('factions = 5');
  } finally {
    await page.request.delete(`/api/scenarios/${created.id}`, { headers });
  }
});
