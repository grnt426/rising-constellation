// System planner plans — plain node, no webpack:
//   node --test front/src/portal/planner/__tests__/plan.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PLAN_FORMAT, PlanError, planFromGame, normalizePlan, planSpeed, buildingChoices, maxLevel,
  infrastructureShortfall, needsInfrastructure, withAncestors, withoutDescendants, computePayload,
  stashPlan, takeStashedPlan, isCapital, walkBodies,
} from '../plan.js';

// A slice of Legacy game data: just enough of each list.
const level = (patent = null) => ({ patent, production: 100, credit: 100, bonus: [] });
const data = {
  stellar_body: [
    { key: 'habitable_planet', biome: 'open' },
    { key: 'sterile_planet', biome: 'dome' },
    { key: 'gaseous_giant', biome: 'none' },
    { key: 'moon', biome: 'orbital' },
  ],
  building: [
    {
      key: 'infra_open', biome: 'open', type: 'infrastructure', limitation: 'unique_body',
      levels: [level('infra_open_1'), level('infra_open_2'), level('infra_open_3')],
    },
    { key: 'factory_open', biome: 'open', type: 'normal', limitation: 'none', levels: [level('open_industries'), level(), level()] },
    { key: 'lift_open', biome: 'open', type: 'normal', limitation: 'unique_body', levels: [level('lift'), level()] },
    { key: 'monument_open', biome: 'open', type: 'normal', limitation: 'unique_system', levels: [level()] },
    { key: 'mine_orbital', biome: 'orbital', type: 'normal', limitation: 'none', levels: [level('orbital_1'), level()] },
    { key: 'mine_dome', biome: 'dome', type: 'normal', limitation: 'none', levels: [level()] },
  ],
  faction: [{ key: 'tetrarchy' }, { key: 'cardan' }],
  character: [{ key: 'admiral' }, { key: 'speaker' }, { key: 'spy' }],
  patent: [
    { key: 'root', ancestor: null },
    { key: 'infra_open_1', ancestor: 'root' },
    { key: 'infra_open_2', ancestor: 'infra_open_1' },
    { key: 'infra_open_3', ancestor: 'infra_open_2' },
    { key: 'open_industries', ancestor: 'infra_open_1' },
  ],
  doctrine: [{ key: 'prod_1' }, { key: 'prod_2' }],
};

const built = (key, lvl, status = 'built') => ({ building_key: key, building_level: lvl, building_status: status });
const empty = () => ({ building_key: null, building_level: null, building_status: 'built' });

function plan(overrides = {}) {
  return {
    format: PLAN_FORMAT,
    version: 1,
    speed: 'slow',
    faction: 'tetrarchy',
    capital: false,
    population: 20,
    bodies: [
      {
        type: 'habitable_planet',
        name: 'Ophion I',
        industrial_factor: 4,
        technological_factor: 2,
        activity_factor: 5,
        tiles: [built('infra_open', 2), built('factory_open', 1), empty(), empty()],
        bodies: [{
          type: 'moon', name: 'Ophion I.a', industrial_factor: 2, technological_factor: 1, activity_factor: 1, tiles: [empty()], bodies: [],
        }],
      },
      {
        type: 'gaseous_giant', name: 'Ophion II', industrial_factor: 0, technological_factor: 0, activity_factor: 0, tiles: [], bodies: [],
      },
    ],
    governor: null,
    patents: null,
    active_lexes: [],
    owned_lexes: null,
    lex_slots: null,
    source: null,
    ...overrides,
  };
}

test('a game system becomes a plan, keeping only finished buildings', () => {
  const system = {
    id: 12,
    name: 'Ophion',
    position: { x: 10.4, y: -3.6 },
    population: { value: 20.456, change: 0.01 },
    production: { value: 140, details: { misc: [{ reason: 'initial', value: 100 }] } },
    bodies: [{
      type: 'habitable_planet',
      name: 'Ophion I',
      industrial_factor: 4,
      technological_factor: 2,
      activity_factor: 5,
      tiles: [
        { building_key: 'infra_open', building_level: 2, building_status: 'built', construction_status: 'upgrade' },
        { building_key: 'factory_open', building_level: 1, building_status: 'damaged', construction_status: 'none' },
        // queued, not built yet
        { building_key: 'lift_open', building_level: null, building_status: 'empty', construction_status: 'new' },
      ],
      bodies: [],
    }],
  };

  const result = planFromGame({
    system,
    speed: 'daily',
    faction: 'cardan',
    constant: { system_capital_base_production: 100, system_base_production: 40 },
    governor: { type: 'speaker', name: 'Vela', skills: [1, 2, 3, 4, 5, 6] },
    patents: ['infra_open_1'],
    activeLexes: ['prod_1'],
    ownedLexes: ['prod_1', 'prod_2'],
    lexSlots: 3,
    sectorName: 'Kelos',
    instanceId: 87,
  });

  assert.equal(result.format, PLAN_FORMAT);
  assert.equal(result.speed, 'slow'); // a daily plans with Legacy data
  assert.equal(result.capital, true);
  assert.equal(result.population, 20.46);
  assert.deepEqual(result.bodies[0].tiles, [
    built('infra_open', 2), built('factory_open', 1, 'damaged'), empty(),
  ]);
  assert.deepEqual(result.governor, { type: 'speaker', name: 'Vela', skills: [1, 2, 3, 4, 5, 6] });
  assert.deepEqual(result.source.position, { x: 10, y: -4 });
  assert.equal(result.source.sector, 'Kelos');
  assert.equal(result.lex_slots, 3);
});

test('a capital is told apart by its base production', () => {
  const constant = { system_capital_base_production: 100, system_base_production: 40 };
  const sys = (value) => ({ production: { details: { misc: [{ reason: 'initial', value }] } } });
  assert.equal(isCapital(sys(100), constant), true);
  assert.equal(isCapital(sys(40), constant), false);
  // Tactic: both 40, it makes no difference
  assert.equal(isCapital(sys(40), { system_capital_base_production: 40, system_base_production: 40 }), false);
  assert.equal(isCapital({}, constant), false);
});

test('only plans are accepted', () => {
  assert.throws(() => planSpeed(null), PlanError);
  assert.throws(() => planSpeed({ bodies: [] }), (e) => e.code === 'not_a_plan');
  assert.throws(() => planSpeed({ format: PLAN_FORMAT, version: 99 }), (e) => e.code === 'newer_version');
  assert.equal(planSpeed({ format: PLAN_FORMAT, speed: 'warp' }), 'slow');
  assert.throws(() => normalizePlan(plan({ bodies: [] }), data), (e) => e.code === 'no_bodies');
});

test('normalizing keeps a valid plan as it is', () => {
  const { plan: result, warnings } = normalizePlan(plan(), data);
  assert.deepEqual(warnings, []);
  assert.deepEqual(result.bodies, plan().bodies);
});

test('normalizing drops what the data cannot hold, and says so', () => {
  const raw = plan({
    faction: 'pirates',
    population: 9999,
    governor: { type: 'speaker', skills: [20, -1, 3] },
    active_lexes: ['prod_1', 'prod_1', 'gone'],
    patents: ['infra_open_1', 'gone'],
  });
  raw.bodies[0].tiles = [
    built('infra_open', 9), // level clamps to 3
    built('mine_dome', 1), // wrong biome
    built('infra_open', 1), // infrastructure on a normal tile
    built('castle', 1), // unknown
    built('lift_open', 1),
    built('lift_open', 1), // second unique-per-body copy
  ];
  raw.bodies[0].bodies[0].tiles = [built('monument_open', 1)]; // open building on a moon

  const { plan: result, warnings } = normalizePlan(raw, data);

  assert.equal(result.faction, 'tetrarchy');
  assert.equal(result.population, 400);
  assert.deepEqual(result.governor.skills, [12, 0, 3, 0, 0, 0]);
  assert.deepEqual(result.active_lexes, ['prod_1']);
  assert.deepEqual(result.patents, ['infra_open_1']);
  assert.deepEqual(result.bodies[0].tiles, [
    built('infra_open', 3), empty(), empty(), empty(), built('lift_open', 1), empty(),
  ]);
  assert.deepEqual(result.bodies[0].bodies[0].tiles, [empty()]);

  const codes = warnings.map((w) => `${w.code}${w.key ? `:${w.key}` : ''}`);
  assert.ok(codes.includes('unknown_faction:pirates'));
  assert.ok(codes.includes('level_changed:infra_open'));
  assert.ok(codes.includes('building_dropped:mine_dome'));
  assert.ok(codes.includes('building_dropped:castle'));
  assert.ok(codes.includes('building_dropped:lift_open'));
  assert.ok(codes.includes('lexes_dropped'));
});

test('a unique-per-system building stays unique across bodies', () => {
  const raw = plan();
  raw.bodies.push({
    ...clonePlanet(raw.bodies[0]),
    tiles: [built('infra_open', 1), built('monument_open', 1)],
  });
  raw.bodies[0].tiles[2] = built('monument_open', 1);

  const { plan: result } = normalizePlan(raw, data);
  assert.equal(result.bodies[0].tiles[2].building_key, 'monument_open');
  assert.equal(result.bodies[2].tiles[1].building_key, null);
});

function clonePlanet(body) {
  return JSON.parse(JSON.stringify({ ...body, bodies: [] }));
}

test('building choices follow biome, tile type, uniqueness and, optionally, patents', () => {
  const p = plan();
  p.bodies[0].tiles[2] = built('lift_open', 1);

  const free = buildingChoices(p, data, [0], 3);
  assert.deepEqual(free.map((c) => c.building.key), ['factory_open', 'lift_open', 'monument_open']);
  assert.equal(free.find((c) => c.building.key === 'lift_open').status, 'disabled');
  assert.equal(free.find((c) => c.building.key === 'factory_open').status, 'buildable');

  // the lift's own tile may keep (or swap) it
  const own = buildingChoices(p, data, [0], 2);
  assert.equal(own.find((c) => c.building.key === 'lift_open').status, 'buildable');

  assert.deepEqual(buildingChoices(p, data, [0], 0).map((c) => c.building.key), ['infra_open']);
  assert.deepEqual(buildingChoices(p, data, [0, 0], 0).map((c) => c.building.key), ['mine_orbital']);

  const researched = buildingChoices(p, data, [0], 3, ['infra_open_1']);
  const factory = researched.find((c) => c.building.key === 'factory_open');
  assert.equal(factory.status, 'locked');
  assert.equal(factory.patent, 'open_industries');
  // no patent needed at level 1
  assert.equal(researched.find((c) => c.building.key === 'monument_open').status, 'buildable');
});

test('patents cap the reachable level', () => {
  const infra = data.building[0];
  assert.equal(maxLevel(infra), 3);
  assert.equal(maxLevel(infra, ['infra_open_1', 'infra_open_2']), 2);
  assert.equal(maxLevel(infra, ['infra_open_2']), 0);
  assert.equal(maxLevel(data.building[1], ['open_industries']), 3);
});

test('the infrastructure level flags buildings above it, except on moons', () => {
  const p = plan();
  const [planet] = p.bodies;
  planet.tiles[1] = built('factory_open', 3);
  assert.equal(infrastructureShortfall(planet, 1), 3);
  planet.tiles[1] = built('factory_open', 2);
  assert.equal(infrastructureShortfall(planet, 1), null);
  assert.equal(infrastructureShortfall(planet, 0), null);

  const moon = planet.bodies[0];
  moon.tiles[0] = built('mine_orbital', 2);
  assert.equal(infrastructureShortfall(moon, 0), null);

  assert.equal(needsInfrastructure(planet, 1), false);
  planet.tiles[0] = empty();
  assert.equal(needsInfrastructure(planet, 1), true);
  assert.equal(infrastructureShortfall(planet, 1), 2);
  assert.equal(needsInfrastructure(moon, 0), false);
});

test('patent ancestry: owning brings the path, dropping takes the branch', () => {
  const list = data.patent;
  assert.deepEqual(withAncestors([], list, 'infra_open_2'), ['root', 'infra_open_1', 'infra_open_2']);
  assert.deepEqual(
    withoutDescendants(['root', 'infra_open_1', 'infra_open_2', 'open_industries'], list, 'infra_open_1'),
    ['root'],
  );
});

test('the compute payload carries what the server reads', () => {
  const p = plan({ governor: { type: 'speaker', name: null, skills: [0, 0, 0, 3, 0, 0] }, active_lexes: ['prod_2'] });
  const payload = computePayload(p, 'Governor');

  assert.deepEqual(Object.keys(payload).sort(), ['bodies', 'capital', 'faction', 'governor', 'lexes', 'population', 'speed']);
  assert.equal(payload.governor.name, 'Governor');
  assert.deepEqual(payload.lexes, ['prod_2']);
  assert.deepEqual(payload.bodies[0].tiles[2], { building_key: null });
  assert.deepEqual(payload.bodies[0].tiles[0], built('infra_open', 2));
  assert.equal(payload.bodies[0].bodies[0].type, 'moon');
});

test('walking bodies yields paths', () => {
  assert.deepEqual(walkBodies(plan().bodies).map(([b, path]) => [b.type, path]), [
    ['habitable_planet', [0]], ['moon', [0, 0]], ['gaseous_giant', [1]],
  ]);
});

test('a stashed plan is handed over once', () => {
  const storage = memoryStorage();
  storage.setItem('rc-planner-import:old', JSON.stringify({ at: 0, plan: {} }));
  storage.setItem('unrelated', 'x');

  const key = stashPlan(storage, plan(), 2 * 24 * 3600 * 1000);
  assert.equal(storage.getItem('rc-planner-import:old'), null); // expired, pruned
  assert.equal(storage.getItem('unrelated'), 'x');

  assert.equal(takeStashedPlan(storage, key).faction, 'tetrarchy');
  assert.equal(takeStashedPlan(storage, key), null);
  assert.equal(takeStashedPlan(storage, '../etc'), null);
});

function memoryStorage() {
  const map = new Map();
  return {
    get length() { return map.size; },
    key: (i) => [...map.keys()][i] ?? null,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}
