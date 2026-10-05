// System planner plans: the JSON a player exports from a star system in
// game, the state the planner page edits, and the body it posts to
// POST /api/system-planner/compute (RC.SystemPlanner computes the result
// with the game's own bonus pipeline, so nothing here does game math).
//
// A plan:
//   {
//     format: 'tf-system-plan', version: 1,
//     speed: 'slow' | 'medium' | 'fast',
//     faction, name, capital, population,
//     bodies: [{ type, name, industrial_factor, technological_factor,
//                activity_factor,
//                tiles: [{ building_key, building_level, building_status }],
//                bodies: [...moons and asteroids] }],
//     governor: null | { type, name, skills: [6 ints] },
//     patents: null | [keys],        // null: nothing imported
//     active_lexes: [keys],
//     owned_lexes: null | [keys],
//     lex_slots: null | number,
//     source: null | { instance_id, system_id, sector, position, exported_at },
//   }
//
// Freeform by design: no costs, no build times, no step-by-step upgrades.
// What the planner still refuses is what no system could ever hold (a
// building on the wrong biome or tile, a level that doesn't exist, a
// second copy of a unique building); the server refuses the same things.
//
// Pure (no Vue, no i18n), so it runs under plain node for tests:
//   node --test front/src/portal/planner/__tests__/plan.test.mjs

export const PLAN_FORMAT = 'tf-system-plan';
export const PLAN_VERSION = 1;

// Legacy, Tactic, Flash: the order the speed picker lists them.
export const SPEEDS = ['slow', 'medium', 'fast'];
export const MAX_POPULATION = 400;
export const MAX_FACTOR = 5;
export const MAX_TILES = 12;
export const MAX_SKILL = 12;
export const SKILL_COUNT = 6;
// Skills 0-2 are the agent's own; 3-5 are the ones a governor applies to
// the system it governs (CharacterCard's "Governor" heading).
export const GOVERNOR_SKILLS = [3, 4, 5];

const MAX_NAME = 60;
const PRIMARY = ['habitable_planet', 'sterile_planet', 'gaseous_giant', 'asteroid_belt'];
// Bodies the infrastructure level doesn't cap (buildingValidation).
const UNCAPPED = ['moon', 'asteroid'];

// A daily is Legacy content at a fast clock.
export function contentSpeed(speed) {
  return speed === 'daily' ? 'slow' : speed;
}

export function isPrimary(body) {
  return PRIMARY.includes(body.type);
}

// The first tile of a top-level body is its infrastructure tile.
export function tileType(body, index) {
  return isPrimary(body) && index === 0 ? 'infrastructure' : 'normal';
}

export function emptyTile() {
  return { building_key: null, building_level: null, building_status: 'built' };
}

export function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

// [body, path] for every body, moons and asteroids included. A path is the
// list of indexes from the top: [1] is the second planet, [1, 0] its moon.
export function walkBodies(bodies, prefix = []) {
  return bodies.flatMap((body, i) => {
    const path = [...prefix, i];
    return [[body, path], ...walkBodies(body.bodies || [], path)];
  });
}

export function bodyAt(plan, path) {
  return path.reduce((acc, i, depth) => (depth === 0 ? plan.bodies[i] : acc.bodies[i]), null);
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function int(value, min, max, fallback) {
  return Number.isFinite(value) ? clamp(Math.round(value), min, max) : fallback;
}

function name(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim().slice(0, MAX_NAME) : null;
}

function keysOf(list) {
  return new Set((list || []).map((item) => item.key));
}

// ---------------------------------------------------------------------------
// From the game

// Build a plan from the in-game system view's data. `system` is
// store.state.game.selectedSystem (a frozen object: never mutated here),
// `constant` is game data's constant row (to tell a capital apart, see
// below) and `governor` the full governor character when the system is
// the player's own (its skills aren't part of the system payload).
export function planFromGame({
  system, speed, faction, constant, governor = null, patents = null,
  ownedLexes = null, activeLexes = [], lexSlots = null, sectorName = null, instanceId = null,
}) {
  const bodies = (system.bodies || []).map(function convert(body) {
    return {
      type: body.type,
      name: body.name,
      industrial_factor: body.industrial_factor,
      technological_factor: body.technological_factor,
      activity_factor: body.activity_factor,
      tiles: (body.tiles || []).map((tile) => (
        ['built', 'damaged'].includes(tile.building_status)
          && tile.building_key && tile.building_key !== 'hidden'
          && Number.isInteger(tile.building_level)
          ? {
            building_key: tile.building_key,
            building_level: tile.building_level,
            building_status: tile.building_status,
          }
          : emptyTile()
      )),
      bodies: (body.bodies || []).map(convert),
    };
  });

  const population = system.population && typeof system.population.value === 'number'
    ? Math.round(system.population.value * 100) / 100
    : 0;

  return {
    format: PLAN_FORMAT,
    version: PLAN_VERSION,
    speed: contentSpeed(speed),
    faction,
    name: system.name || null,
    capital: isCapital(system, constant),
    population,
    bodies,
    governor: governor && Array.isArray(governor.skills)
      ? { type: governor.type, name: governor.name || null, skills: [...governor.skills] }
      : null,
    patents: patents ? [...patents] : null,
    active_lexes: [...(activeLexes || [])],
    owned_lexes: ownedLexes ? [...ownedLexes] : null,
    lex_slots: Number.isInteger(lexSlots) ? lexSlots : null,
    source: {
      instance_id: instanceId,
      system_id: system.id,
      sector: sectorName,
      position: system.position
        ? { x: Math.round(system.position.x), y: Math.round(system.position.y) }
        : null,
      exported_at: new Date().toISOString(),
    },
  };
}

// The client is never told which system is the capital, but a capital's
// base production differs (Legacy 100 vs 40, Flash 40 vs 30), and the
// production breakdown names it. Where both are equal (Tactic) it makes
// no difference to the plan either way.
export function isCapital(system, constant) {
  if (!constant || !system.production || !system.production.details) return false;
  const misc = system.production.details.misc || [];
  const initial = misc.find((part) => part.reason === 'initial');
  return !!initial
    && constant.system_capital_base_production !== constant.system_base_production
    && initial.value === constant.system_capital_base_production;
}

// ---------------------------------------------------------------------------
// Validating a plan (imports, pasted JSON, speed changes)

export class PlanError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

// The speed to load data for before normalizePlan can run.
export function planSpeed(raw) {
  if (!raw || typeof raw !== 'object') throw new PlanError('not_a_plan');
  if (raw.format !== PLAN_FORMAT) throw new PlanError('not_a_plan');
  if (Number.isInteger(raw.version) && raw.version > PLAN_VERSION) throw new PlanError('newer_version');
  const speed = contentSpeed(raw.speed);
  return SPEEDS.includes(speed) ? speed : 'slow';
}

// Fit `raw` to the game data of its speed. Never throws past planSpeed:
// whatever can't be kept is dropped and reported in `warnings`
// ({ code, key? }) so the page can say what changed.
export function normalizePlan(raw, data) {
  const speed = planSpeed(raw);
  const warnings = [];
  const warn = (code, key) => {
    if (!warnings.some((w) => w.code === code && w.key === key)) warnings.push(key ? { code, key } : { code });
  };

  const bodyKeys = keysOf(data.stellar_body);
  const factions = keysOf(data.faction);
  const characters = keysOf(data.character);
  const patents = keysOf(data.patent);
  const lexes = keysOf(data.doctrine);

  const faction = factions.has(raw.faction) ? raw.faction : (data.faction[0] || {}).key;
  if (raw.faction && faction !== raw.faction) warn('unknown_faction', raw.faction);

  const fitBody = (body, primary) => {
    if (!body || !bodyKeys.has(body.type) || isPrimary(body) !== primary) return null;
    const fitted = {
      type: body.type,
      name: name(body.name),
      industrial_factor: int(body.industrial_factor, 0, MAX_FACTOR, 0),
      technological_factor: int(body.technological_factor, 0, MAX_FACTOR, 0),
      activity_factor: int(body.activity_factor, 0, MAX_FACTOR, 0),
      tiles: [],
      bodies: [],
    };
    fitted.tiles = (Array.isArray(body.tiles) ? body.tiles : []).slice(0, MAX_TILES)
      .map((tile, i) => fitTile(tile, fitted, i));
    fitted.bodies = primary && Array.isArray(body.bodies)
      ? body.bodies.map((b) => fitBody(b, false)).filter((b) => b !== null)
      : [];
    return fitted;
  };

  const fitTile = (tile, body, index) => {
    if (!tile || !tile.building_key) return emptyTile();
    const building = data.building.find((b) => b.key === tile.building_key);
    if (!building || building.biome !== biomeOf(data, body) || building.type !== tileType(body, index)) {
      warn('building_dropped', tile.building_key);
      return emptyTile();
    }
    const max = building.levels.length;
    const level = int(tile.building_level, 1, max, 1);
    if (level !== tile.building_level) warn('level_changed', building.key);
    return {
      building_key: building.key,
      building_level: level,
      building_status: tile.building_status === 'damaged' ? 'damaged' : 'built',
    };
  };

  const bodies = (Array.isArray(raw.bodies) ? raw.bodies : [])
    .map((body) => fitBody(body, true))
    .filter((body) => body !== null);
  if (bodies.length === 0) throw new PlanError('no_bodies');

  dropDuplicateUniques(bodies, data, warn);

  let governor = null;
  if (raw.governor && characters.has(raw.governor.type) && Array.isArray(raw.governor.skills)) {
    governor = {
      type: raw.governor.type,
      name: name(raw.governor.name),
      skills: Array.from({ length: SKILL_COUNT }, (_, i) => int(raw.governor.skills[i], 0, MAX_SKILL, 0)),
    };
  } else if (raw.governor) {
    warn('governor_dropped');
  }

  const known = (list, set, code) => {
    if (!Array.isArray(list)) return null;
    const kept = [...new Set(list)].filter((key) => set.has(key));
    if (kept.length < new Set(list).size) warn(code);
    return kept;
  };

  return {
    plan: {
      format: PLAN_FORMAT,
      version: PLAN_VERSION,
      speed,
      faction,
      name: name(raw.name),
      capital: raw.capital === true,
      population: Number.isFinite(raw.population)
        ? clamp(Math.round(raw.population * 100) / 100, 0, MAX_POPULATION)
        : 0,
      bodies,
      governor,
      patents: known(raw.patents, patents, 'patents_dropped'),
      active_lexes: known(raw.active_lexes, lexes, 'lexes_dropped') || [],
      owned_lexes: known(raw.owned_lexes, lexes, 'lexes_dropped'),
      lex_slots: Number.isInteger(raw.lex_slots) ? raw.lex_slots : null,
      source: raw.source && typeof raw.source === 'object' ? {
        instance_id: Number.isInteger(raw.source.instance_id) ? raw.source.instance_id : null,
        system_id: Number.isInteger(raw.source.system_id) ? raw.source.system_id : null,
        sector: name(raw.source.sector),
        position: raw.source.position && Number.isFinite(raw.source.position.x)
          ? { x: raw.source.position.x, y: raw.source.position.y }
          : null,
        exported_at: typeof raw.source.exported_at === 'string' ? raw.source.exported_at : null,
      } : null,
    },
    warnings,
  };
}

// The server's template (GET /api/system-planner/template) as a plan.
export function planFromTemplate(template, faction, data) {
  return normalizePlan({
    ...template,
    format: PLAN_FORMAT,
    version: PLAN_VERSION,
    faction,
    governor: null,
    patents: null,
    active_lexes: [],
    owned_lexes: null,
    lex_slots: null,
    source: null,
  }, data).plan;
}

function biomeOf(data, body) {
  const bodyData = data.stellar_body.find((b) => b.key === body.type);
  return bodyData ? bodyData.biome : null;
}

// Keep the first copy of each unique building, in body order.
function dropDuplicateUniques(bodies, data, warn) {
  const seenSystem = new Set();
  walkBodies(bodies).forEach(([body]) => {
    const seenBody = new Set();
    body.tiles.forEach((tile, i) => {
      if (!tile.building_key) return;
      const building = data.building.find((b) => b.key === tile.building_key);
      const limit = building && building.limitation;
      const clash = (limit === 'unique_body' && seenBody.has(tile.building_key))
        || (limit === 'unique_system' && seenSystem.has(tile.building_key));
      if (clash) {
        warn('building_dropped', tile.building_key);
        body.tiles[i] = emptyTile();
        return;
      }
      seenBody.add(tile.building_key);
      if (limit === 'unique_system') seenSystem.add(tile.building_key);
    });
  });
}

// ---------------------------------------------------------------------------
// Building rules

// What `tile` of the body at `path` can hold: [{ building, status, reason,
// patent }] with status 'buildable' | 'locked' (a missing patent; only when
// `patents` is a list) | 'disabled' (a unique building already elsewhere).
// The tile's own building never counts against its uniqueness, so a
// building can always be swapped for another.
export function buildingChoices(plan, data, path, tileIndex, patents = null) {
  const body = bodyAt(plan, path);
  if (!body) return [];
  const biome = biomeOf(data, body);
  const type = tileType(body, tileIndex);

  const others = walkBodies(plan.bodies).flatMap(([b, p]) => b.tiles
    .map((tile, i) => ({ tile, sameBody: samePath(p, path), self: samePath(p, path) && i === tileIndex }))
    .filter(({ tile, self }) => tile.building_key && !self));

  return data.building
    .filter((b) => b.biome === biome && b.type === type)
    .map((building) => {
      const patent = building.levels[0].patent;
      let status = 'buildable';
      let reason = null;

      if (patents && patent && !patents.includes(patent)) {
        status = 'locked';
        reason = 'patent';
      }
      if (building.limitation === 'unique_body'
        && others.some(({ tile, sameBody }) => sameBody && tile.building_key === building.key)) {
        status = 'disabled';
        reason = 'unique_body';
      }
      if (building.limitation === 'unique_system'
        && others.some(({ tile }) => tile.building_key === building.key)) {
        status = 'disabled';
        reason = 'unique_system';
      }

      return {
        building, status, reason, patent: status === 'locked' ? patent : null,
      };
    });
}

function samePath(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

// Highest level reachable with `patents` (every level up to it unlocked),
// or the building's last level when patents aren't limiting.
export function maxLevel(building, patents = null) {
  if (!patents) return building.levels.length;
  let level = 0;
  for (let i = 0; i < building.levels.length; i += 1) {
    const { patent } = building.levels[i];
    if (patent && !patents.includes(patent)) break;
    level = i + 1;
  }
  return level;
}

// In game a building can't be raised above its planet's infrastructure
// level (moons, asteroids and the infrastructure itself excepted). The
// planner allows it but flags the tile: returns the level the
// infrastructure needs, or null when the tile is fine.
export function infrastructureShortfall(body, tileIndex) {
  if (UNCAPPED.includes(body.type) || tileType(body, tileIndex) === 'infrastructure') return null;
  const tile = body.tiles[tileIndex];
  if (!tile || !tile.building_key) return null;
  const infra = body.tiles[0];
  const infraLevel = infra && infra.building_key ? infra.building_level : 0;
  return tile.building_level > infraLevel ? tile.building_level : null;
}

// In game a planet's other tiles open once its infrastructure is built.
export function needsInfrastructure(body, tileIndex) {
  return isPrimary(body) && tileIndex > 0 && !(body.tiles[0] && body.tiles[0].building_key);
}

// ---------------------------------------------------------------------------
// Patents and lexes (the planner's drawers)

// Owning a patent means owning the path to it.
export function withAncestors(keys, list, key) {
  const byKey = new Map(list.map((item) => [item.key, item]));
  const result = new Set(keys);
  let current = byKey.get(key);
  while (current) {
    result.add(current.key);
    current = current.ancestor ? byKey.get(current.ancestor) : null;
  }
  return list.map((item) => item.key).filter((k) => result.has(k));
}

// Dropping a patent drops everything researched through it.
export function withoutDescendants(keys, list, key) {
  const children = new Map();
  list.forEach((item) => {
    if (!item.ancestor) return;
    if (!children.has(item.ancestor)) children.set(item.ancestor, []);
    children.get(item.ancestor).push(item.key);
  });
  const removed = new Set();
  const stack = [key];
  while (stack.length) {
    const k = stack.pop();
    if (!removed.has(k)) {
      removed.add(k);
      stack.push(...(children.get(k) || []));
    }
  }
  return keys.filter((k) => !removed.has(k));
}

// ---------------------------------------------------------------------------
// To the server

export function computePayload(plan, governorName = null) {
  const body = (b) => ({
    type: b.type,
    name: b.name,
    industrial_factor: b.industrial_factor,
    technological_factor: b.technological_factor,
    activity_factor: b.activity_factor,
    tiles: b.tiles.map((tile) => (tile.building_key ? {
      building_key: tile.building_key,
      building_level: tile.building_level,
      building_status: tile.building_status,
    } : { building_key: null })),
    bodies: (b.bodies || []).map(body),
  });

  return {
    speed: plan.speed,
    faction: plan.faction,
    capital: plan.capital,
    population: plan.population,
    bodies: plan.bodies.map(body),
    governor: plan.governor ? {
      type: plan.governor.type,
      name: plan.governor.name || governorName,
      skills: plan.governor.skills,
    } : null,
    lexes: plan.active_lexes,
  };
}

// ---------------------------------------------------------------------------
// Opening the planner from the game

// The game hands a plan to a new planner tab through localStorage (same
// origin, no size worries, nothing in the URL): the tab is opened on
// ?import=<key> and takes the entry, which is deleted on read. Entries a
// tab never picked up are dropped after a day.
const STASH_PREFIX = 'rc-planner-import:';
const STASH_TTL = 24 * 3600 * 1000;

export function stashPlan(storage, plan, now = Date.now()) {
  const keys = [];
  for (let i = 0; i < storage.length; i += 1) keys.push(storage.key(i));
  keys.filter((k) => k && k.startsWith(STASH_PREFIX)).forEach((k) => {
    try {
      const { at } = JSON.parse(storage.getItem(k));
      if (!(now - at < STASH_TTL)) storage.removeItem(k);
    } catch (e) {
      storage.removeItem(k);
    }
  });

  const key = `${now.toString(36)}${Math.random().toString(36).slice(2, 8)}`;
  storage.setItem(STASH_PREFIX + key, JSON.stringify({ at: now, plan }));
  return key;
}

export function takeStashedPlan(storage, key) {
  if (!key || !/^[a-z0-9]+$/.test(key)) return null;
  const raw = storage.getItem(STASH_PREFIX + key);
  storage.removeItem(STASH_PREFIX + key);
  if (!raw) return null;
  try {
    return JSON.parse(raw).plan || null;
  } catch (e) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Opening a ready-made example (?preset=<name>)

// The help manual links to example systems by name; the server holds them
// (GET /system-planner/preset/:name). Anything that isn't a plain name is
// refused before it reaches a URL.
export function presetName(value) {
  const name = typeof value === 'string' ? value : '';
  return /^[a-z0-9][a-z0-9-]{0,40}$/.test(name) ? name : null;
}

// Whether a saved session holds work a preset would wipe out: edits made
// since its baseline, or a system brought over from a game. The untouched
// starting system is not worth a question.
export function sessionAtRisk(saved) {
  if (!saved || !saved.plan) return false;
  if (saved.plan.source) return true;
  return !!saved.baseline && JSON.stringify(saved.plan) !== JSON.stringify(saved.baseline);
}
