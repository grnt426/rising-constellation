// Page-side driver: everything runs inside the real SPA via
// page.evaluate, so orders/moves exercise the actual client pipeline
// (socket push → broadcast → store commit → render), not a parallel
// reimplementation. The Vue root is the bridge: #app.__vue__.$store.

// Seed the five auth cookies the /game route reads (mirrors the game/init
// mutation), so the test can land directly in the game.
async function seedGameCookies(context, baseURL, payload) {
  const url = new URL(baseURL);
  const cookies = ['faction', 'instance', 'profile', 'registration_token', 'user_token']
    .filter((k) => payload[k] !== undefined && payload[k] !== null)
    .map((name) => ({
      name,
      value: String(payload[name]),
      domain: url.hostname,
      path: '/',
    }));
  await context.addCookies(cookies);
}

async function waitConnected(page) {
  await page.waitForFunction(() => {
    const app = document.querySelector('#app');
    return app && app.__vue__ && app.__vue__.$store.state.game.connected === true;
  }, { timeout: 60000 });
}

// Wrap the game socket with counters so the spec can assert HOW the
// client synced (slim deltas vs full refetches), not just that it did.
async function instrument(page) {
  await page.evaluate(() => {
    const app = document.querySelector('#app').__vue__;
    const sock = app.$socket;
    window.__e2e = {
      getSystem: 0, getCharacter: 0, getPlayer: 0,
      playerProduction: 0, playerPlayer: 0, errors: [],
    };
    const wrapPush = (channel, counters) => {
      const orig = channel.push.bind(channel);
      channel.push = (event, payload) => {
        if (counters[event] !== undefined) window.__e2e[counters[event]] += 1;
        return orig(event, payload);
      };
    };
    wrapPush(sock.faction, { get_system: 'getSystem' });
    wrapPush(sock.player, { get_character: 'getCharacter', get_player: 'getPlayer' });
    sock.player.on('broadcast', (data) => {
      if (data.player_production) window.__e2e.playerProduction += 1;
      if (data.player_player) window.__e2e.playerPlayer += 1;
    });
    window.addEventListener('error', (e) => window.__e2e.errors.push(String(e.message)));
  });
}

function counters(page) {
  return page.evaluate(() => ({ ...window.__e2e }));
}

// Open a system through the real store action (get_system round trip).
async function openSystem(page, systemId) {
  await page.evaluate((id) => {
    const app = document.querySelector('#app').__vue__;
    return app.$store.dispatch('game/openSystem', { vm: app, id });
  }, systemId);
  await page.waitForFunction(
    (id) => {
      const s = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
      return s && s.id === id;
    },
    systemId,
    { timeout: 15000 },
  );
}

// Push a player-channel event and resolve with 'ok' | {error} | 'timeout'.
function playerPush(page, event, payload) {
  return page.evaluate(({ event: ev, payload: pl }) => new Promise((resolve) => {
    document.querySelector('#app').__vue__.$socket.player
      .push(ev, pl)
      .receive('ok', (data) => resolve({ ok: true, data }))
      .receive('error', (err) => resolve({ ok: false, error: err && err.reason }))
      .receive('timeout', () => resolve({ ok: false, error: 'timeout' }));
  }), { event, payload });
}

// Snapshot of everything the scenario asserts on, taken from the store.
function snapshot(page) {
  return page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const sys = st.selectedSystem;
    const tiles = [];
    const walk = (bodies) => (bodies || []).forEach((b) => {
      (b.tiles || []).forEach((t) => tiles.push({
        body: b.uid, bodyType: b.type, id: t.id, key: t.building_key, level: t.building_level,
        status: t.building_status, construction: t.construction_status, type: t.type,
      }));
      walk(b.bodies);
    });
    if (sys) walk(sys.bodies);
    return {
      credit: st.player.credit ? { value: st.player.credit.value, change: st.player.credit.change } : null,
      technology: st.player.technology
        ? { value: st.player.technology.value, change: st.player.technology.change } : null,
      systems: (st.player.stellar_systems || []).map((s) => ({ id: s.id, name: s.name, queue: s.queue })),
      characters: (st.player.characters || []).map((c) => ({ id: c.id, type: c.type, system: c.system, status: c.status })),
      selected: sys ? {
        id: sys.id,
        queue: ((sys.queue && sys.queue.queue) || []).map((q) => ({ id: q.id, key: q.prod_key, type: q.type })),
        usedWorkforce: sys.used_workforce,
        tiles,
      } : null,
      frozen: {
        player: Object.isFrozen(st.player),
        system: sys ? Object.isFrozen(sys) : null,
      },
    };
  });
}

// Legal build candidates for the selected system, derived from the same
// frozen game data the real picker uses: biome match, infra-first on
// virgin bodies, skip tiles already building and unique-limited
// buildings. A fresh player owns ZERO patents (everything, even level-1
// infrastructure, is patent-gated), so each candidate carries its
// level-1 patent and whether it's owned or purchasable (root patent,
// affordable with current technology). Sorted: owned first, then
// cheapest purchasable.
async function pickBuildCandidates(page) {
  return page.evaluate(() => {
    const st = document.querySelector('#app').__vue__.$store.state.game;
    const sys = st.selectedSystem;
    if (!sys) return [];
    const { data } = st;
    const owned = new Set(st.player.patents || []);
    const tech = st.player.technology ? st.player.technology.value : 0;
    const patentByKey = new Map((data.patent || []).map((p) => [p.key, p]));
    const biomeOf = (bodyType) => {
      const bd = (data.stellar_body || []).find((b) => b.key === bodyType);
      return bd ? bd.biome : null;
    };
    // Keys already present (built OR planned) — for the unique_body /
    // unique_system limitation checks. `limitation` is the string 'none'
    // when a building has no cap.
    const systemKeys = new Set();
    const bodyKeys = new Map(); // uid -> Set of keys
    const index = (bodies) => (bodies || []).forEach((body) => {
      const keys = new Set();
      (body.tiles || []).forEach((t) => {
        if (t.building_key) { keys.add(t.building_key); systemKeys.add(t.building_key); }
      });
      bodyKeys.set(body.uid, keys);
      index(body.bodies);
    });
    index(sys.bodies);

    const limitationOk = (b, bodyUid) => {
      if (b.limitation === 'unique_system') return !systemKeys.has(b.key);
      if (b.limitation === 'unique_body') return !(bodyKeys.get(bodyUid) || new Set()).has(b.key);
      return true;
    };

    const out = [];
    const consider = (body, tileId, b) => {
      if (!limitationOk(b, body.uid)) return;
      const lvl1 = (b.levels || []).find((l) => l.level === 1) || (b.levels || [])[0];
      const patentKey = lvl1 ? lvl1.patent : null;
      const patent = patentKey ? patentByKey.get(patentKey) : null;
      const patentOwned = !patentKey || owned.has(patentKey);
      const ancestorOk = !patent || !patent.ancestor || owned.has(patent.ancestor);
      const purchasable = !patentOwned && !!patent && ancestorOk && patent.cost <= tech;
      if (patentOwned || purchasable) {
        out.push({
          body: body.uid, tile: tileId, key: b.key, patent: patentKey, patentOwned, cost: patent ? patent.cost : 0,
        });
      }
    };

    const walk = (bodies) => {
      (bodies || []).forEach((body) => {
        const biome = biomeOf(body.type);
        const tiles = body.tiles || [];
        const infraTile = tiles.find((t) => t.id === 1);

        if (infraTile && !infraTile.building_key && infraTile.construction_status === 'none') {
          (data.building || [])
            .filter((b) => b.type === 'infrastructure' && b.biome === biome && b.key !== 'hypergate')
            .forEach((b) => consider(body, 1, b));
        }

        if (infraTile && infraTile.building_status === 'built') {
          const t = tiles.find((x) => x.id !== 1 && x.type === 'normal'
            && !x.building_key && x.construction_status === 'none');
          if (t) {
            (data.building || [])
              .filter((b) => b.type === 'normal' && b.biome === biome)
              .forEach((b) => consider(body, t.id, b));
          }
        }

        walk(body.bodies);
      });
    };
    walk(sys.bodies);

    out.sort((a, b) => (Number(b.patentOwned) - Number(a.patentOwned)) || (a.cost - b.cost));
    return out.slice(0, 12);
  });
}

// Wait until the slim delta lands: the ordered tile flips out of
// construction_status 'none' in the (frozen, replaced) selectedSystem.
async function waitTilePlanned(page, spot) {
  await page.waitForFunction(({ body, tile }) => {
    const sys = document.querySelector('#app').__vue__.$store.state.game.selectedSystem;
    if (!sys) return false;
    const find = (bodies) => {
      for (const b of bodies || []) {
        if (b.uid === body) return (b.tiles || []).find((t) => t.id === tile);
        const sub = find(b.bodies);
        if (sub) return sub;
      }
      return null;
    };
    const t = find(sys.bodies);
    return !!t && (t.construction_status !== 'none' || t.building_status === 'built');
  }, spot, { timeout: 10000 });
}

// Creator-tier speed cheat (the fixture enables cheats and its caller is
// the creator): compresses real production/travel/colonization timelines
// into test budgets. Phoenix buffers pushes made before the join lands.
async function setSpeedCheat(page, multiplier) {
  return page.evaluate((mult) => new Promise((resolve) => {
    const sock = document.querySelector('#app').__vue__.$socket;
    const channel = sock.joinCheat();
    channel.push('set_speed', { multiplier: mult })
      .receive('ok', (data) => resolve({ ok: true, data }))
      .receive('error', (err) => resolve({ ok: false, error: err && err.reason }))
      .receive('timeout', () => resolve({ ok: false, error: 'timeout' }));
  }), multiplier);
}

// Server-truth snapshot via the new get_player handler.
async function serverPlayer(page) {
  const res = await playerPush(page, 'get_player', {});
  if (!res.ok) throw new Error(`get_player failed: ${res.error}`);
  return res.data.player_player;
}

module.exports = {
  seedGameCookies,
  waitConnected,
  instrument,
  counters,
  openSystem,
  playerPush,
  snapshot,
  serverPlayer,
  pickBuildCandidates,
  waitTilePlanned,
  setSpeedCheat,
};
