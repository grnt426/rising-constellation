// Scenario Workshop (Sandbox → Scenario Workshop, docs/scenario-scripting.md).
//
// The first test is the onboarding path a newcomer takes: the tour opens on
// the First Steps example, and its four tasks (change a value, add a step,
// simulate, look at the code) are done the way the tour words them. The
// test counts the gestures and the time it takes and writes them to
// test-results/workshop-onboarding.json, which the design doc quotes.
//
// The rest pin down what the editor promises: text and nodes are one
// program (an edit on either side shows on the other), steps group into a
// named function, mistakes are explained where they are, and the simulator
// runs a scenario, races included.
const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { Api } = require('../helpers/api');

const PLAYER = { email: 'user1@abc', password: 'user1dev' };
const node = (page, title) => page.locator(`.wk-node:has(> .wk-head .wk-title:text-is("${title}"))`);

async function signIn(page, baseURL) {
  const api = new Api(page.request, baseURL);
  const token = await api.login(PLAYER.email, PLAYER.password);
  const url = new URL(baseURL);
  await page.context().addCookies([{
    name: 'user_token', value: token, domain: url.hostname, path: '/',
  }]);
}

async function openWorkshop(page) {
  await page.goto('/portal/scenario-workshop');
  await expect(page.locator('.wk-node').first()).toBeVisible({ timeout: 60000 });
}

// A first visit opens the tour once the example has loaded.
async function endTour(page) {
  const end = page.locator('.wk-tour-card button', { hasText: 'End the tour' });
  await end.waitFor();
  await end.click();
}

async function setView(page, label) {
  await page.locator('.wk-views button', { hasText: label }).click();
}

const codeText = (page) => page.locator('.wk-input').inputValue();

test.beforeEach(async ({ page, baseURL }) => {
  await signIn(page, baseURL);
});

test('a newcomer finishes the tour on the first example', async ({ page }) => {
  const started = Date.now();
  let gestures = 0;
  const did = async (fn) => { gestures += 1; await fn(); };

  await openWorkshop(page);
  const card = page.locator('.wk-tour-card');
  await expect(card).toContainText('This is a scenario');
  await expect(card).toContainText('1 / 7');

  // 1-2: reading
  await did(() => card.locator('button', { hasText: 'Next' }).click());
  await expect(card).toContainText('Events start things');
  await did(() => card.locator('button', { hasText: 'Next' }).click());

  // 3: change a value, as the card says: the 500 in the * node becomes 1000
  await expect(card).toContainText('Change a value');
  const op = page.locator('.wk-node.shape-op').first();
  const literal = op.locator('.wk-row input[type="text"]').first();
  await expect(literal).toHaveValue('500');
  await did(async () => {
    await literal.fill('1000');
    await literal.press('Enter');
  });
  await expect(card).toContainText('Add a step', { timeout: 10000 });

  // 4: drag notify from the palette onto the bottom pin of the chain's last node
  const before = await page.locator('.wk-node').count();
  const lastNotify = node(page, 'notify').last();
  await did(() => page.locator('.wk-palette-item:has(.wk-palette-label:text-is("notify"))').dragTo(lastNotify.locator('.wk-exec-out')));
  await expect(card).toContainText('See it run', { timeout: 10000 });
  await expect(page.locator('.wk-node')).toHaveCount(before + 1);

  // 5: simulate
  await did(() => page.locator('[data-tour="simulate"]').click());
  await expect(page.locator('.wk-sim-score strong')).toBeVisible();
  await expect(card).toContainText('The same scenario, as code', { timeout: 10000 });

  // 6: the code, with both edits in it
  await did(() => setView(page, 'Both'));
  await expect(card).toContainText('Over to you', { timeout: 10000 });
  const text = await codeText(page);
  expect(text).toContain('let amount = 1000 * gift');
  expect(text.match(/notify\(/g).length).toBe(3);

  // 7: done
  await did(() => card.locator('button', { hasText: 'Start building' }).click());
  await expect(card).toHaveCount(0);

  // the scenario the newcomer built runs: seven gifts of 1000, 2000 …
  const steps = page.locator('.wk-timeline li');
  await expect(steps).toHaveCount(8);
  await expect(steps.nth(1)).toContainText('+1,000 credit');

  const seconds = (Date.now() - started) / 1000;
  const out = path.join(__dirname, '..', 'test-results', 'workshop-onboarding.json');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ gestures, seconds, steps: 7, finished: true }, null, 2));
});

test('text and nodes are one program', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  await setView(page, 'Both');

  // an edit in the text shows in the nodes
  const source = await codeText(page);
  await page.locator('.wk-input').fill(source.replace('500 * gift', '750 * gift'));
  await expect(page.locator('.wk-node.shape-op .wk-row input[type="text"]').first()).toHaveValue('750', { timeout: 10000 });

  // and an edit in the nodes shows in the text
  const interval = node(page, 'every').locator('.wk-row:has(.wk-label:text-is("interval")) input');
  await interval.fill('1m');
  await interval.press('Enter');
  await expect.poll(() => codeText(page), { timeout: 10000 }).toContain('every 1m as gift {');

  // selecting a node highlights its line
  await node(page, 'give').locator('.wk-head').click();
  const active = page.locator('.wk-gutter-line.is-active');
  await expect(active).toHaveCount(1);
  const line = Number(await active.textContent());
  expect((await codeText(page)).split('\n')[line - 1]).toContain('give(');

  // a syntax error keeps the nodes as they were and says where
  await page.locator('.wk-input').fill(`${await codeText(page)}\nevery {`);
  await expect(page.locator('.wk-banner')).toContainText('Line', { timeout: 10000 });
  await expect(node(page, 'give')).toBeVisible();
});

test('steps group into a named function, which saves to the library', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);

  // the give and the notify after it, in the every chain
  await node(page, 'give').locator('.wk-head').click();
  await node(page, 'notify').last().locator('.wk-head').click({ modifiers: ['Shift'] });
  page.once('dialog', (d) => d.accept('reward'));
  await page.locator('.wk-canvas').press('Control+g');

  await expect(page.locator('.wk-frame-title', { hasText: 'fn reward(amount)' })).toBeVisible({ timeout: 10000 });
  await setView(page, 'Code');
  await expect.poll(() => codeText(page), { timeout: 10000 }).toContain('fn reward(amount) {');
  expect(await codeText(page)).toContain('  reward(amount)');

  // and the grouped scenario still does the same thing
  await page.locator('[data-tour="simulate"]').click();
  await expect(page.locator('.wk-timeline li')).toHaveCount(8);

  // save it, then insert it into a blank scenario
  await setView(page, 'Nodes');
  await page.locator('.wk-frame-title', { hasText: 'fn reward' }).click({ button: 'right' });
  await page.locator('.wk-menu button', { hasText: 'Save to my library' }).click();
  await page.selectOption('.wk-new select', '__blank');
  await expect(page.locator('.wk-scenario-name')).toHaveText('My scenario');
  await page.locator('.wk-palette-search').fill('reward');
  await page.locator('.wk-palette-item:has(.wk-palette-label:text-is("reward(amount)"))').first().click();
  await expect(page.locator('.wk-frame-title', { hasText: 'fn reward(amount)' })).toBeVisible({ timeout: 10000 });
});

test('mistakes are explained where they are', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  await setView(page, 'Both');

  const source = await codeText(page);
  await page.locator('.wk-input').fill(source.replace('score player.credit', 'score player.credt').replace('give("credit"', 'give("credits"'));

  const tab = page.locator('.wk-tabs button', { hasText: 'Problems' });
  await expect(tab.locator('.wk-badge')).toHaveText('2', { timeout: 10000 });
  await tab.click();
  await expect(page.locator('.wk-problems')).toContainText('did you mean credit?');
  await expect(page.locator('.wk-node.has-error')).toHaveCount(2);
  await expect(page.locator('.wk-gutter-line.has-error')).toHaveCount(2);

  // the tool knows the right names: one click each puts them back
  await page.locator('.wk-fix', { hasText: 'Fix: use credit' }).first().click();
  await expect(tab.locator('.wk-badge')).toHaveText('1', { timeout: 10000 });
  await page.locator('.wk-fix', { hasText: 'Fix: use credit' }).first().click();
  await expect(tab.locator('.wk-badge')).toHaveCount(0, { timeout: 10000 });
  expect(await codeText(page)).toContain('score player.credit');
});

test('a playtest runs the script in a real game and comes back', async ({ page }) => {
  test.setTimeout(240000);
  await openWorkshop(page);
  await endTour(page);
  await setView(page, 'Code');

  await page.locator('.wk-input').fill([
    'setup {',
    '  name = "Quick playtest"',
    '  time_limit = 5m',
    '}',
    '',
    'score player.credit',
    '',
    'on start {',
    '  give("credit", 5000)',
    '  notify("Welcome to the playtest!", tone: "good")',
    '}',
    '',
    'at 6s {',
    '  finish("All done")',
    '}',
    '',
  ].join('\n'));
  await expect(page.locator('.wk-scenario-name')).toHaveText('Quick playtest', { timeout: 10000 });

  await page.locator('[data-tour="playtest"]').click();
  await expect(page).toHaveURL(/\/portal\/game/, { timeout: 60000 });

  // the script's message, as plain text, its live score, then its finish
  await expect(page.locator('.scenario-message', { hasText: 'Welcome to the playtest!' })).toBeVisible({ timeout: 90000 });
  await expect(page.locator('.scenario-status')).toContainText('Quick playtest');
  await page.screenshot({ path: 'test-results/playtest-message.png' });
  const banner = page.locator('.daily-result-panel');
  await expect(banner).toContainText('Scenario complete!', { timeout: 60000 });
  await expect(banner).toContainText('All done');
  const score = Number((await banner.locator('.big-value').textContent()).replace(/[^\d]/g, ''));
  expect(score).toBeGreaterThanOrEqual(5000);

  await page.screenshot({ path: 'test-results/playtest-banner.png' });
  await banner.locator('.daily-result-exit').click();
  await expect(page).toHaveURL(/\/portal\/scenario-workshop/, { timeout: 30000 });
  await expect(page.locator('.wk-scenario-name')).toHaveText('Quick playtest', { timeout: 30000 });
});

test('a race simulates to the finish once its goal is pretended', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  await page.selectOption('.wk-examples select', 'destroyers_blueprint');
  await expect(page.locator('.wk-scenario-name')).toHaveText("The Destroyer's Blueprint", { timeout: 10000 });

  await page.locator('[data-tour="simulate"]').click();
  await expect(page.locator('.wk-sim-end')).toContainText('Ran to the deadline');

  await page.locator('.wk-pretend summary').click();
  await page.locator('.wk-pretend button', { hasText: 'what-if' }).click({ timeout: 10000 });
  await page.locator('[data-tour="simulate"]').click();
  await expect(page.locator('.wk-sim-end')).toContainText('Finished at 15:00 with 15:00 left');
  await expect(page.locator('.wk-sim-score strong')).toHaveText('15:00 left');
  await expect(page.locator('.wk-sim-goal')).toHaveCount(0);
});

// --- files ------------------------------------------------------------------------

async function fileMenu(page, item) {
  await page.locator('.wk-file').click();
  await page.locator('.wk-menu button', { hasText: item }).click();
}

async function downloaded(page, run) {
  const [download] = await Promise.all([page.waitForEvent('download'), run()]);
  const file = await download.path();
  return { name: download.suggestedFilename(), text: fs.readFileSync(file, 'utf8'), file };
}

test('scripts open from and save to .edict files', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);

  // Save writes the canonical text, named after the scenario
  const saved = await downloaded(page, () => fileMenu(page, 'Save as file'));
  expect(saved.name).toBe('first-steps.edict');
  expect(saved.text).toContain('name = "First Steps"');

  // Open reads a file written on Windows (CRLF, comments and all)
  const script = [
    '# Written in another editor.',
    'setup {',
    '  name = "From a file"',
    '  time_limit = 10m',
    '}',
    '',
    '# Credits at the deadline.',
    'score player.credit',
    '',
  ].join('\r\n');
  await page.locator('input[type="file"]').first().setInputFiles({
    name: 'from-a-file.edict', mimeType: 'text/plain', buffer: Buffer.from(script),
  });
  await expect(page.locator('.wk-scenario-name')).toHaveText('From a file', { timeout: 10000 });
  await expect(page.locator('.wk-banner')).toHaveCount(0);

  // Ctrl+S saves too, from the code view
  await setView(page, 'Code');
  const again = await downloaded(page, () => page.locator('.wk-input').press('Control+s'));
  expect(again.name).toBe('from-a-file.edict');
  expect(again.text).toContain('# Credits at the deadline.');
});

// A file handle the test controls, standing in for the File System Access
// API's (the real one needs a native picker).
async function fakeFilePicker(page, name, text) {
  await page.evaluate(([n, t]) => {
    const file = { name: n, text: t, modified: 1, writes: 0 };
    window.fakeFile = file;
    const handle = {
      kind: 'file',
      name: n,
      getFile: async () => new File([file.text], file.name, { lastModified: file.modified }),
      requestPermission: async () => 'granted',
      createWritable: async () => {
        let next = '';
        return {
          write: async (chunk) => { next += chunk; },
          close: async () => {
            file.text = next;
            file.modified += 1;
            file.writes += 1;
          },
        };
      },
    };
    window.showOpenFilePicker = async () => [handle];
  }, [name, text]);
}

test('a linked file keeps the workshop in step with another editor', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  const first = 'setup {\n  name = "Linked"\n  time_limit = 10m\n}\n\nscore player.credit\n';
  await fakeFilePicker(page, 'linked.edict', first);
  await fileMenu(page, 'Link a file');
  await expect(page.locator('.wk-scenario-name')).toHaveText('Linked', { timeout: 10000 });
  await expect(page.locator('.wk-link')).toContainText('linked.edict');
  await expect(page.locator('.wk-link')).toContainText('linked');

  // saved in the other editor: the workshop follows, keeping that text as written
  const edited = first.replace('"Linked"', '"Edited elsewhere"').replace('score player.credit', 'score   player.technology');
  await page.evaluate((t) => {
    window.fakeFile.text = t;
    window.fakeFile.modified += 1;
  }, edited);
  await expect(page.locator('.wk-scenario-name')).toHaveText('Edited elsewhere', { timeout: 10000 });
  await setView(page, 'Code');
  expect(await codeText(page)).toBe(edited);

  // a change here shows Save; Ctrl+S writes it back to the file
  await page.locator('.wk-input').fill(edited.replace('time_limit = 10m', 'time_limit = 12m'));
  await expect(page.locator('.wk-link-save')).toBeVisible({ timeout: 10000 });
  await page.locator('.wk-input').press('Control+s');
  await expect(page.locator('.wk-link-save')).toHaveCount(0, { timeout: 10000 });
  const file = await page.evaluate(() => window.fakeFile);
  expect(file.writes).toBe(1);
  expect(file.text).toContain('time_limit = 12m');

  // both sides changed: the author is asked, and can keep the workshop's
  await page.locator('.wk-input').fill(file.text.replace('12m', '14m'));
  await expect(page.locator('.wk-link-save')).toBeVisible({ timeout: 10000 });
  page.once('dialog', (d) => d.dismiss());
  await page.evaluate(() => {
    window.fakeFile.text = window.fakeFile.text.replace('12m', '13m');
    window.fakeFile.modified += 1;
  });
  await page.waitForTimeout(2500);
  expect(await codeText(page)).toContain('time_limit = 14m');

  await fileMenu(page, 'Stop following');
  await expect(page.locator('.wk-link')).toHaveCount(0);
});

test('functions export to a file and import from one', async ({ page, baseURL }) => {
  await openWorkshop(page);
  await endTour(page);

  const lib = [
    '# Shared by a friend.',
    '',
    '# Double a gift.',
    'fn doubled(x) {',
    '  return x * 2',
    '}',
    '',
    'fn halved(x) {',
    '  return x / 2',
    '}',
    '',
    'score 1',
    '',
  ].join('\n');
  await fileMenu(page, 'Import functions');
  await page.locator('input[type="file"]').nth(1).setInputFiles({
    name: 'friends.edict', mimeType: 'text/plain', buffer: Buffer.from(lib),
  });
  await expect(page.locator('.toasted').last()).toContainText('Added to your library from friends.edict: 2', { timeout: 10000 });
  await page.locator('.wk-palette-search').fill('doubled');
  await expect(page.locator('.wk-palette-label:text-is("doubled(x)")')).toBeVisible();

  const out = await downloaded(page, () => fileMenu(page, 'Export my functions'));
  expect(out.name).toBe('my-functions.edict');
  expect(out.text).toContain('fn doubled(x) {');
  expect(out.text).toContain('fn halved(x) {');
  expect(out.text).not.toContain('score 1');

  // the export reads back as a file of functions
  const api = new Api(page.request, baseURL);
  await api.login(PLAYER.email, PLAYER.password);
  const res = await page.request.post('/api/edict/analyze', { data: { source: out.text }, headers: api.authHeaders(PLAYER.email) });
  expect(res.status()).toBe(200);
  const body = await res.json();
  expect(body.program.decls.filter((d) => d.k === 'fn').map((d) => d.name)).toEqual(['doubled', 'halved']);
});

test('editor kits download from the help tab', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  await fileMenu(page, 'Use your own editor');
  await expect(page.locator('.wk-help h3', { hasText: 'Use your own editor' })).toBeVisible();

  const vsix = await downloaded(page, () => page.locator('.wk-editor-kits button', { hasText: 'VS Code' }).click());
  expect(vsix.name).toMatch(/^edict-\d+\.\d+\.\d+\.vsix$/);
  const kit = await downloaded(page, () => page.locator('.wk-editor-kits button', { hasText: 'All editors' }).click());
  expect(kit.name).toMatch(/^edict-editor-kit-\d+\.\d+\.\d+\.zip$/);
  // zips start with PK
  expect(fs.readFileSync(kit.file).slice(0, 2).toString()).toBe('PK');
});

// A file someone sent can carry markup in its name and anywhere in its
// text. Every way the workshop shows it (toasts, tooltips, the code view,
// problems, the palette, the simulator) must show it as text.
test('markup in a file never runs, wherever the workshop shows it', async ({ page }) => {
  await openWorkshop(page);
  await endTour(page);
  await page.evaluate(() => { window.pwned = []; });
  const hook = (n) => `<img src=x onerror="window.pwned.push(${n})">`;
  const script = [
    `# ${hook(1)}`,
    'setup {',
    `  name = "${hook(2).replace(/"/g, "'")}"`,
    `  mutators = ["${hook(3).replace(/"/g, "'")}"]`,
    '}',
    '',
    'score player.credit',
    '',
    `# ${hook(4)}`,
    'fn helper(x) {',
    '  return x',
    '}',
    '',
    'on start {',
    `  give("${hook(5).replace(/"/g, "'")}", 5)`,
    `  notify("${hook(6).replace(/"/g, "'")}")`,
    `  log("${hook(7).replace(/"/g, "'")}")`,
    '}',
    '',
  ].join('\n');
  const file = { name: `${hook(8).replace(/[/"]/g, '')}.edict`, mimeType: 'text/plain', buffer: Buffer.from(script) };

  await page.locator('input[type="file"]').first().setInputFiles(file);
  await expect(page.locator('.toasted').last()).toContainText('<img', { timeout: 10000 });
  await expect(page.locator('.wk-node.has-error').first()).toBeVisible({ timeout: 10000 });

  // the problem badges' tooltips
  const badges = page.locator('.wk-problem');
  for (let i = 0; i < await badges.count(); i += 1) {
    await badges.nth(i).hover();
    await page.waitForTimeout(300);
  }
  await page.locator('.wk-tabs button', { hasText: 'Problems' }).click();
  await setView(page, 'Both');
  await fileMenu(page, 'Import functions');
  await page.locator('input[type="file"]').nth(1).setInputFiles(file);
  await page.locator('.wk-palette-search').fill('helper');
  await page.locator('.wk-tabs button', { hasText: 'Simulate' }).click();
  await page.locator('[data-tour="simulate"]').click();
  await page.waitForTimeout(1500);

  expect(await page.evaluate(() => window.pwned)).toEqual([]);
});
