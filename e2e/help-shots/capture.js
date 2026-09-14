#!/usr/bin/env node
// Help-manual screenshot pipeline. Boots a real game against this
// worktree's Docker dev stack, captures the UI elements listed in
// shots.json and records highlight boxes ("marks") as fractions of each
// image. See README.md.
//
//   node e2e/help-shots/capture.js [--date=YYYY-MM-DD] [--headed] [name ...]
//
// No names = every enabled recipe. Naming a disabled recipe runs it anyway.
const fs = require('fs');
const path = require('path');
const { chromium, request } = require('@playwright/test');
const { Api } = require('../helpers/api');
const { seedGameCookies } = require('../helpers/game');

const ROOT = path.resolve(__dirname, '..', '..');
const RECIPES_FILE = path.join(__dirname, 'shots.json');
const ASSETS_DIR = path.join(ROOT, 'assets', 'static', 'img', 'help', 'shots');
const PRIV_DIR = path.join(ROOT, 'priv', 'static', 'img', 'help', 'shots');
const MANIFEST_FILE = path.join(ROOT, 'priv', 'help', 'shots', 'manifest.json');
const DEBUG_DIR = path.join(ROOT, 'e2e', 'screens'); // gitignored

const VIEWPORT = { width: 1440, height: 900 };
const NEUTRAL_MOUSE = { x: 1250, y: 780 }; // empty map area beside the system view

const EMAIL = process.env.RC_HELP_SHOTS_EMAIL || 'user1@abc';
const PASSWORD = process.env.RC_HELP_SHOTS_PASSWORD || 'user1dev';

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const opts = { names: [], date: null, headed: false, baseURL: null };
  argv.forEach((arg) => {
    if (arg.startsWith('--date=')) opts.date = arg.slice(7);
    else if (arg === '--headed') opts.headed = true;
    else if (arg.startsWith('--base-url=')) opts.baseURL = arg.slice(11);
    else if (arg.startsWith('--')) throw new Error(`unknown flag ${arg}`);
    else opts.names.push(arg);
  });
  if (!opts.baseURL) {
    const ports = JSON.parse(fs.readFileSync(path.join(ROOT, '.dev-ports.json'), 'utf8')).ports;
    opts.baseURL = `http://localhost:${ports.phoenix}`;
  }
  if (!opts.date) {
    const d = new Date();
    const pad2 = (n) => String(n).padStart(2, '0');
    opts.date = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`; // local date
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.date)) throw new Error(`--date must be YYYY-MM-DD, got ${opts.date}`);
  return opts;
}

// ---------------------------------------------------------------- session

// One login per run: repeated logins trip the auth rate limiter.
async function apiSession(baseURL) {
  const req = await request.newContext();
  const res = await req.post(`${baseURL}/api/auth/identity/callback`, {
    data: { account: { email: EMAIL, password: PASSWORD } },
  });
  if (!res.ok()) throw new Error(`login ${EMAIL} failed: ${res.status()} ${await res.text()}`);
  const body = await res.json();
  const token = body.access_token || body.token;
  return { req, token, account: body.account, headers: { Authorization: `Bearer ${token}` } };
}

// Seeded non-admin accounts have no profile; create one like the portal does.
async function ensureProfile(baseURL, session) {
  const url = `${baseURL}/api/accounts/${session.account.id}/profiles`;
  const res = await session.req.get(url, { headers: session.headers });
  if (!res.ok()) throw new Error(`profiles failed: ${res.status()} ${await res.text()}`);
  const body = await res.json();
  const list = Array.isArray(body) ? body : (body.data || []);
  if (list.length) return list[0];

  const created = await session.req.post(url, {
    headers: session.headers,
    data: { profile: { name: session.account.name || 'User1', avatar: 'avatarM_001.jpg' } },
  });
  if (!created.ok()) throw new Error(`profile create failed: ${created.status()} ${await created.text()}`);
  const cbody = await created.json();
  return cbody.data || cbody;
}

// ---------------------------------------------------------------- page helpers

// Right after an rc restart the dev server can hand out a page that never
// connects (it is still warming up), so give it one reload before failing.
async function waitConnected(page) {
  const connected = () => {
    const app = document.querySelector('#app');
    const st = app && app.__vue__ && app.__vue__.$store.state.game;
    return st && st.connected === true && st.player && (st.player.stellar_systems || []).length > 0;
  };
  try {
    try {
      await page.waitForFunction(connected, null, { timeout: 60000 });
    } catch (first) {
      console.log('  game not connected after 60 s, reloading once');
      await page.reload();
      await page.waitForFunction(connected, null, { timeout: 90000 });
    }
  } catch (e) {
    // say what the page looked like, instead of a bare timeout
    const state = await page.evaluate(() => {
      const app = document.querySelector('#app');
      const st = app && app.__vue__ && app.__vue__.$store.state.game;
      if (!st) return { store: false, text: document.body.innerText.slice(0, 200) };
      return { connected: st.connected, player: !!st.player, systems: st.player ? (st.player.stellar_systems || []).length : null };
    }).catch((err) => ({ evaluateFailed: err.message }));
    fs.mkdirSync(DEBUG_DIR, { recursive: true });
    const shot = path.join(DEBUG_DIR, 'help-shot-scene-connect-failed.png');
    await page.screenshot({ path: shot }).catch(() => {});
    throw new Error(`game never connected at ${page.url()}: ${JSON.stringify(state)} (page screenshot: ${path.relative(ROOT, shot)})`);
  }
}

// Open any system through the real store action (get_system round trip).
async function openSystemById(page, id) {
  await page.evaluate((sid) => {
    const root = document.querySelector('#app').__vue__;
    root.$store.dispatch('game/openSystem', { vm: root, id: sid });
  }, id);
  await page.waitForFunction((sid) => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    return s && s.id === sid;
  }, id, { timeout: 20000 });
  await page.locator('.system-population').waitFor({ state: 'visible' });
  await page.locator('.system-content-scrollbar, .system-content-container .system-content-orphan').first()
    .waitFor({ state: 'visible' });
  if (await page.locator('.system-content-scrollbar').count() === 0) {
    throw new Error(`system ${id} shows no bodies (hidden: no visibility on it, or no bodies)`);
  }
  // the boxes slide in (gsap); wait for them to settle
  await waitStable(page, '.system-population');
  await waitStable(page, '.system-properties');
  await waitStable(page, '.system-content-container');
  return id;
}

async function openOwnSystem(page) {
  const id = await page.evaluate(() => document.querySelector('#app').__vue__.$store.state.game.player.stellar_systems[0].id);
  return openSystemById(page, id);
}

async function selectedSystemId(page) {
  return page.evaluate(() => {
    const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    return s ? s.id : null;
  });
}

// Back to the bodies tab if a recipe switched tabs (open-state-tab).
// Content.vue keeps its activeTab across system changes, and a
// single-tab system (uninhabited) opened on tab 2 fails to render, so run
// this before switching systems too.
async function backToBodiesTab(page) {
  const bodiesTab = page.locator('.system-content-menu .system-tab-item:not(.is-tool)').first();
  if (await bodiesTab.count() && !(await bodiesTab.getAttribute('class')).split(/\s+/).includes('active')) {
    await bodiesTab.click();
    await page.locator('.system-content-scrollbar .system-content-group-item').first().waitFor({ state: 'visible', timeout: 5000 });
    await waitStable(page, '.system-content-container');
  }
}

async function waitStable(page, selector, timeout = 5000) {
  const loc = page.locator(selector).first();
  const deadline = Date.now() + timeout;
  let prev = null;
  while (Date.now() < deadline) {
    const box = await loc.boundingBox();
    if (box && prev && ['x', 'y', 'width', 'height'].every((k) => Math.abs(box[k] - prev[k]) < 0.5)) return box;
    prev = box;
    await page.waitForTimeout(120);
  }
  throw new Error(`element never settled: ${selector}`);
}

async function closeTransientUi(page) {
  await page.keyboard.press('Escape'); // unpins HoverPopover
  await page.mouse.move(NEUTRAL_MOUSE.x, NEUTRAL_MOUSE.y);
  await page.evaluate(() => {
    const store = document.querySelector('#app').__vue__.$store;
    if (store.state.game.production) store.commit('game/clearProduction');
  });
  await page.locator('.tooltip.popover.open').waitFor({ state: 'detached', timeout: 3000 }).catch(() => {});
  await page.locator('.system-building-card').waitFor({ state: 'detached', timeout: 3000 }).catch(() => {});
  await page.waitForTimeout(250);
}

// ---------------------------------------------------------------- scenes
//
// A scene boots once per run and returns { page, reset }. reset() runs
// before every recipe of that scene so recipes don't leak state.

const scenes = {
  'own-system': async ({ browser, baseURL, session }) => {
    const profile = await ensureProfile(baseURL, session);
    const res = await session.req.post(`${baseURL}/api/daily/play`, {
      headers: session.headers,
      data: { profile_id: profile.id },
    });
    if (!res.ok()) throw new Error(`daily/play failed: ${res.status()} ${await res.text()}`);
    const payload = await res.json();
    console.log(`  daily instance ${payload.instance} booted for profile ${payload.profile}`);

    const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1 });
    const host = new URL(baseURL).hostname;
    await context.addCookies(['faction', 'instance', 'profile', 'registration_token', 'user_token']
      .filter((k) => payload[k] !== undefined && payload[k] !== null)
      .map((name) => ({ name, value: String(payload[name]), domain: host, path: '/' })));

    const page = await context.newPage();
    await page.goto(`${baseURL}/portal/game`);
    await waitConnected(page);
    await page.waitForTimeout(1500);
    const systemId = await openOwnSystem(page);

    return {
      page,
      reset: async () => {
        await closeTransientUi(page);
        const stillOpen = await page.evaluate((sid) => {
          const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
          return !!s && s.id === sid;
        }, systemId);
        if (!stillOpen) await openOwnSystem(page);
        await backToBodiesTab(page);
      },
    };
  },

  // Agent fixture with the `empire` option (DevFixtureController): the
  // player holds two systems (home destabilized) and one dominion, next to
  // an autonomous and an uninhabited system. A recipe picks the open system
  // with `openSystem` (EMPIRE_SYSTEMS, default "home").
  empire: async ({ browser, baseURL, session }) => {
    const api = new Api(session.req, baseURL);
    api.tokens.set(EMAIL, session.token);
    // "slow" = Legacy, the speed the manual documents (a Flash capital
    // starts at 40 production, a Legacy one at 100)
    const fixture = await api.createAgentFixture(EMAIL, null, null, null, null, 'slow', true);
    if (!fixture.empire) {
      throw new Error('agent-fixture returned no "empire" block: the running server does not have the empire option compiled in');
    }
    const ids = fixture.empire;
    console.log(`  fixture instance ${fixture.instance_id}: home ${ids.home}, owned2 ${ids.owned2}, `
      + `dominion ${ids.dominion}, autonomous ${ids.autonomous}, uninhabited ${ids.uninhabited}, `
      + `destabilized ${ids.destabilized} (${ids.population_status})`);

    const reg = await api.registrationToken(EMAIL, fixture.instance_id);
    const start = await api.gameStartPayload(EMAIL, fixture.instance_id, reg.token);
    const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1 });
    await seedGameCookies(context, baseURL, start);

    const page = await context.newPage();
    await page.goto(`${baseURL}/portal/game`);
    await waitConnected(page);
    await page.waitForFunction(() => {
      const { player } = document.querySelector('#app').__vue__.$store.state.game;
      return (player.stellar_systems || []).length >= 2 && (player.dominions || []).length >= 1;
    }, null, { timeout: 30000 });
    await page.waitForTimeout(1500);

    const systemFor = (recipe) => {
      const key = (recipe && recipe.openSystem) || 'home';
      if (!EMPIRE_SYSTEMS.includes(key)) throw new Error(`openSystem "${key}" must be one of ${EMPIRE_SYSTEMS.join(', ')}`);
      if (!ids[key]) throw new Error(`the fixture returned no "${key}" system`);
      return ids[key];
    };
    await openSystemById(page, ids.home);

    return {
      page,
      reset: async (recipe) => {
        await closeTransientUi(page);
        const target = systemFor(recipe);
        if (await selectedSystemId(page) !== target) {
          if (await selectedSystemId(page) !== null) await backToBodiesTab(page);
          await openSystemById(page, target);
        }
        await backToBodiesTab(page);
        // scroll-state-into-view leaves the panel scrolled
        await page.evaluate(() => {
          const el = document.querySelector('.system-content-scrollbar');
          if (el) el.scrollTop = 0;
        });
      },
    };
  },
};

// `openSystem` keys a recipe of the empire scene can use
const EMPIRE_SYSTEMS = ['home', 'owned2', 'dominion', 'autonomous', 'uninhabited', 'destabilized'];

// ---------------------------------------------------------------- prepare steps

// dispatch: fire the click event on the trigger itself instead of clicking
// at its position, for a trigger that another element covers.
async function pinPopover(page, triggerSelector, { dispatch = false } = {}) {
  const trigger = page.locator(triggerSelector);
  if (await trigger.count() === 0) throw new Error(`prepare: trigger not found: ${triggerSelector}`);
  if (dispatch) await trigger.dispatchEvent('click');
  else await trigger.click();
  await page.mouse.move(NEUTRAL_MOUSE.x, NEUTRAL_MOUSE.y); // pinned: stays open
  await page.locator('.tooltip.popover.open .resource-detail').waitFor({ state: 'visible', timeout: 5000 });
  await waitStable(page, '.tooltip.popover.open .tooltip-inner');
}

const prepares = {
  'pin-credit-popover': (page) => pinPopover(page, '.system-properties .yields .hover-popover-trigger >> nth=0'),
  'pin-stability-popover': (page) => pinPopover(page, '.system-population .box-line:not(.header) .hover-popover-trigger >> nth=2'),
  // At 1440x900 the bottom-anchored .system-info (population + bodies list,
  // z-index above .system-content) covers the production value, so a real
  // click lands on .system-info. Dispatch the click to the trigger instead;
  // HoverPopover pins on it the same way.
  'pin-production-popover': (page) => pinPopover(page, '.system-properties .production-box .hover-popover-trigger', { dispatch: true }),
  // The defense value is a plain v-popover (trigger="hover"): no pinning, so
  // the pointer has to stay on the trigger through the capture.
  'hover-defense-popover': async (page) => {
    const trigger = page.locator('.system-properties .box-aside.left .v-popover .trigger');
    if (await trigger.count() === 0) throw new Error('prepare: defense trigger not found (system has no defense value?)');
    await trigger.hover();
    await page.locator('.tooltip.popover.open .resource-detail').waitFor({ state: 'visible', timeout: 5000 });
    await waitStable(page, '.tooltip.popover.open .tooltip-inner');
  },
  // Content.vue tabs: bodies, details, state (+ the collapse tool button).
  // The operations group (buttons) only exists on your own systems and
  // dominions; on anyone else's system wait on the claim group instead.
  'open-state-tab': async (page) => {
    await page.locator('.system-content-menu .system-tab-item:not(.is-tool) >> nth=2').click();
    await page.locator('.system-content-scrollbar .system-content-group-info').waitFor({ state: 'visible', timeout: 5000 });
    const operations = '.system-content-scrollbar .system-content-group:has(> .button)';
    const claim = '.system-content-scrollbar .system-content-group:has(.system-content-group-info)';
    await waitStable(page, await page.locator(operations).count() ? operations : claim);
  },
  // Bottombar technology value: the second HoverPopover of the left group.
  'pin-empire-technology-popover': (page) => pinPopover(page, '.navbar.bottom .navbar-group-buttons.left .hover-popover-trigger >> nth=1'),
  // Bottombar Systems counter: a plain v-popover (trigger="hover"), the
  // first .v-popover of the left group; the pointer stays on it.
  'hover-systems-limit-popover': async (page) => {
    const trigger = page.locator('.navbar.bottom .navbar-group-buttons.left .v-popover .trigger >> nth=0');
    if (await trigger.count() === 0) throw new Error('prepare: Systems counter not found in the bottom bar');
    await trigger.hover();
    await page.locator('.tooltip.popover.open .resource-detail').waitFor({ state: 'visible', timeout: 5000 });
    await waitStable(page, '.tooltip.popover.open .tooltip-inner');
  },
  // Bottombar: the Systems and Dominions counters are plain v-popovers; the
  // first HoverPopover of the left group is the empire's credit.
  'pin-empire-credit-popover': (page) => pinPopover(page, '.navbar.bottom .navbar-group-buttons.left .hover-popover-trigger >> nth=0'),
  // A single-tab system (uninhabited) lists its state group under the
  // bodies; scroll the panel so the group is on screen.
  'scroll-state-into-view': async (page) => {
    const selector = '.system-content-scrollbar .system-content-group:has(.system-content-group-info)';
    const group = page.locator(selector).first();
    if (await group.count() === 0) throw new Error('prepare: no state group in the system panel');
    await group.evaluate((el) => el.scrollIntoView({ block: 'end' }));
    await page.waitForTimeout(150);
    await waitStable(page, selector);
  },
  // Hover the first built building's icon in the bodies list; the card
  // hangs beside the panel while the pointer stays on the tile.
  'hover-built-building': async (page) => {
    const icon = page.locator('.system-content-group .body-tiles .tile:has(.tile-level) .tile-icon').first();
    if (await icon.count() === 0) throw new Error('prepare: no built building tile in the bodies list');
    await icon.hover();
    await page.locator('.system-building-card .card-container').waitFor({ state: 'visible', timeout: 5000 });
    await waitStable(page, '.system-building-card .card-container');
  },
};

// ---------------------------------------------------------------- measuring

// Mark spec: "selector" | { selector, ownText?, optional? } | [spec, ...] (union).
// Selectors are Playwright selectors (CSS plus :has-text(), >> nth=N, ...).
// In a union, an optional member that is absent is left out; any other
// absent member makes the whole union absent.
async function measureSpec(page, spec) {
  if (Array.isArray(spec)) {
    const found = [];
    for (const s of spec) {
      const box = await measureSpec(page, s);
      if (box) found.push(box);
      else if (!(s && s.optional)) return null;
    }
    if (!found.length) return null;
    const x1 = Math.min(...found.map((b) => b.x));
    const y1 = Math.min(...found.map((b) => b.y));
    const x2 = Math.max(...found.map((b) => b.x + b.width));
    const y2 = Math.max(...found.map((b) => b.y + b.height));
    return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
  }
  const selector = typeof spec === 'string' ? spec : spec.selector;
  const loc = page.locator(selector);
  if (await loc.count() === 0) return null;
  const el = loc.first();
  if (!await el.isVisible()) return null;
  if (typeof spec === 'object' && spec.ownText) {
    // box of the element's direct, non-blank text nodes (e.g. the growth
    // adjective next to a <strong> title)
    return el.evaluate((node) => {
      const rects = [];
      node.childNodes.forEach((child) => {
        if (child.nodeType === Node.TEXT_NODE && child.textContent.trim()) {
          const range = document.createRange();
          range.selectNodeContents(child);
          Array.from(range.getClientRects()).forEach((r) => { if (r.width && r.height) rects.push(r); });
        }
      });
      if (!rects.length) return null;
      const x1 = Math.min(...rects.map((r) => r.left));
      const y1 = Math.min(...rects.map((r) => r.top));
      const x2 = Math.max(...rects.map((r) => r.right));
      const y2 = Math.max(...rects.map((r) => r.bottom));
      return { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };
    });
  }
  return el.boundingBox();
}

const round4 = (n) => Math.round(n * 10000) / 10000;

function markFraction(box, clip) {
  const x1 = Math.max(box.x, clip.x);
  const y1 = Math.max(box.y, clip.y);
  const x2 = Math.min(box.x + box.width, clip.x + clip.width);
  const y2 = Math.min(box.y + box.height, clip.y + clip.height);
  if (x2 <= x1 || y2 <= y1) return null;
  return {
    x: round4((x1 - clip.x) / clip.width),
    y: round4((y1 - clip.y) / clip.height),
    w: round4((x2 - x1) / clip.width),
    h: round4((y2 - y1) / clip.height),
  };
}

function pngSize(buffer) {
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

// ---------------------------------------------------------------- manifest

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object') {
    return Object.keys(value).sort().reduce((acc, k) => { acc[k] = sortKeys(value[k]); return acc; }, {});
  }
  return value;
}

function writeManifest(entries) {
  let manifest = { shots: {} };
  if (fs.existsSync(MANIFEST_FILE)) manifest = JSON.parse(fs.readFileSync(MANIFEST_FILE, 'utf8'));
  manifest.shots = manifest.shots || {};
  Object.assign(manifest.shots, entries);
  fs.mkdirSync(path.dirname(MANIFEST_FILE), { recursive: true });
  fs.writeFileSync(MANIFEST_FILE, `${JSON.stringify(sortKeys(manifest), null, 2)}\n`);
}

// ---------------------------------------------------------------- recipe runner

async function captureRecipe(page, recipe, date) {
  if (recipe.prepare) {
    const prep = prepares[recipe.prepare];
    if (!prep) throw new Error(`unknown prepare step "${recipe.prepare}"`);
    await prep(page);
  }

  const target = await measureSpec(page, recipe.selector);
  if (!target) throw new Error(`selector not found or not visible: ${recipe.selector}`);

  // measure marks before the screenshot, while the UI is in the prepared state
  const markBoxes = {};
  for (const [key, spec] of Object.entries(recipe.marks || {})) {
    const box = await measureSpec(page, spec);
    if (!box) {
      if (spec && spec.optional) {
        console.log(`    mark "${key}" not present (optional, skipped)`);
        continue;
      }
      throw new Error(`mark "${key}" not found: ${JSON.stringify(spec)}`);
    }
    markBoxes[key] = box;
  }

  const pad = recipe.padding || 0;
  const x1 = Math.max(0, Math.floor(target.x - pad));
  const y1 = Math.max(0, Math.floor(target.y - pad));
  const x2 = Math.min(VIEWPORT.width, Math.ceil(target.x + target.width + pad));
  const y2 = Math.min(VIEWPORT.height, Math.ceil(target.y + target.height + pad));
  const clip = { x: x1, y: y1, width: x2 - x1, height: y2 - y1 };

  const marks = {};
  for (const [key, box] of Object.entries(markBoxes)) {
    const frac = markFraction(box, clip);
    if (!frac) throw new Error(`mark "${key}" lies outside the captured area`);
    marks[key] = frac;
  }

  const buffer = await page.screenshot({ clip, caret: 'hide' });
  const { width, height } = pngSize(buffer);
  const file = `${recipe.name}.png`;
  fs.mkdirSync(ASSETS_DIR, { recursive: true });
  fs.mkdirSync(PRIV_DIR, { recursive: true });
  fs.writeFileSync(path.join(ASSETS_DIR, file), buffer);
  fs.copyFileSync(path.join(ASSETS_DIR, file), path.join(PRIV_DIR, file));

  return {
    alt: recipe.alt || '',
    captured: date,
    file,
    height,
    marks,
    scene: recipe.scene,
    width,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const all = JSON.parse(fs.readFileSync(RECIPES_FILE, 'utf8'));
  const byName = new Map(all.map((r) => [r.name, r]));

  const failures = [];
  let selected;
  if (opts.names.length) {
    selected = [];
    opts.names.forEach((n) => {
      if (byName.has(n)) selected.push(byName.get(n));
      else failures.push({ name: n, error: 'no such recipe in shots.json' });
    });
  } else {
    selected = all.filter((r) => {
      if (r.disabled) console.log(`skip ${r.name}: disabled (${r.disabled})`);
      return !r.disabled;
    });
  }

  const entries = {};
  if (selected.length) {
    const session = await apiSession(opts.baseURL);
    const browser = await chromium.launch({ headless: !opts.headed });
    const booted = new Map(); // scene name -> { page, reset } | Error
    try {
      for (const recipe of selected) {
        console.log(`shot ${recipe.name} (scene ${recipe.scene})`);
        try {
          if (!scenes[recipe.scene]) throw new Error(`unknown scene "${recipe.scene}"`);
          if (!booted.has(recipe.scene)) {
            try {
              booted.set(recipe.scene, await scenes[recipe.scene]({ browser, baseURL: opts.baseURL, session }));
            } catch (e) {
              booted.set(recipe.scene, e);
            }
          }
          const scene = booted.get(recipe.scene);
          if (scene instanceof Error) throw new Error(`scene "${recipe.scene}" failed to boot: ${scene.message}`);
          await scene.reset(recipe);
          try {
            entries[recipe.name] = await captureRecipe(scene.page, recipe, opts.date);
          } catch (e) {
            fs.mkdirSync(DEBUG_DIR, { recursive: true });
            const debugPath = path.join(DEBUG_DIR, `help-shot-${recipe.name}-failed.png`);
            await scene.page.screenshot({ path: debugPath }).catch(() => {});
            throw new Error(`${e.message} (page screenshot: ${path.relative(ROOT, debugPath)})`);
          }
          const e = entries[recipe.name];
          console.log(`  ok ${e.file} ${e.width}x${e.height} marks: ${Object.keys(e.marks).join(', ') || '-'}`);
        } catch (e) {
          failures.push({ name: recipe.name, error: e.message });
          console.error(`  FAILED ${recipe.name}: ${e.message}`);
        }
      }
    } finally {
      await browser.close();
      await session.req.dispose();
    }
  }

  if (Object.keys(entries).length) {
    writeManifest(entries);
    console.log(`manifest: ${path.relative(ROOT, MANIFEST_FILE)} (${Object.keys(entries).length} updated)`);
  }
  if (failures.length) {
    console.error(`\n${failures.length} recipe(s) failed:`);
    failures.forEach((f) => console.error(`  ${f.name}: ${f.error}`));
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch((e) => { console.error(e); process.exit(1); });
}

// for ad-hoc probes (boot the scene, inspect the DOM) without a capture run
module.exports = { scenes, prepares, apiSession, measureSpec, waitStable, openSystemById, VIEWPORT };
