// System briefing text — plain node, real English strings:
//   node --test front/src/game/a11y/__tests__/system-brief.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import * as brief from '../system-brief.js';

const here = new URL('.', import.meta.url);
const load = (file) => JSON.parse(readFileSync(new URL(`../../../locales/en/${file}`, here), 'utf8'));
const messages = { ...load('game.json'), ...load('data.json') };

function lookup(key) {
  // vue-i18n paths: dots, plus `skills[0]` style indexes
  return key.replace(/\[(\d+)\]/g, '.$1').split('.')
    .reduce((node, part) => (node == null ? undefined : node[part]), messages);
}

function interpolate(text, params = {}) {
  return text.replace(/\{(\w+)\}/g, (_, name) => (name in params ? String(params[name]) : `{${name}}`));
}

const player = {
  id: 1, name: 'Me', faction: 'tetrarchy', faction_id: 1, dominions_under_attack: [], patents: [],
  characters: [
    { id: 10, type: 'spy', name: 'Shade', level: 2, action_status: 'idle', is_discovered: true, actions: { queue: [] } },
    { id: 11, type: 'speaker', name: 'Voice', level: 3, action_status: 'idle', speaker: { cooldown: { value: 5 } }, actions: { queue: [] } },
  ],
};

function vm(overrides = {}) {
  return {
    $t: (key, params) => {
      const text = lookup(key);
      return typeof text === 'string' ? interpolate(text, params) : key;
    },
    $tc: (key, n, params) => {
      const text = lookup(key);
      if (typeof text !== 'string') return key;
      const forms = text.split('|').map((f) => f.trim());
      const form = forms.length === 1 ? forms[0] : forms[n === 1 ? 0 : 1];
      return interpolate(form, params);
    },
    $te: (key) => typeof lookup(key) === 'string',
    $store: {
      state: {
        game: {
          player: { ...player, ...(overrides.player || {}) },
          data: {
            population_status: [{ key: 'normal', penalty: 0 }, { key: 'uprising', penalty: 0.3 }],
            bonus_pipeline_in: [
              { key: 'direct', from: 'none' },
              { key: 'body_ind', from: 'stellar_body', from_key: 'industrial_factor' },
            ],
            constant: [{ character_level_wages: 10 }],
          },
        },
      },
      getters: {},
    },
    $options: { filters: { income: (v) => String(Math.round(v)), integer: (v) => String(Math.round(v)) } },
  };
}

const agent = (id, type, name, owner) => ({ id, type, name, level: 4, owner, armada_id: null });
const ME = { id: 1, name: 'Me', faction: 'tetrarchy', faction_id: 1 };
const ALLY = { id: 2, name: 'Ally', faction: 'tetrarchy', faction_id: 1 };
const RIVAL = { id: 3, name: 'Rival', faction: 'cardan', faction_id: 2 };

function system(extra = {}) {
  return {
    id: 7,
    name: 'Khesia',
    status: 'inhabited_player',
    owner: ME,
    contact: { value: 5, details: {} },
    siege: null,
    queue: { queue: [] },
    workforce: 8,
    used_workforce: 9,
    population_status: 'normal',
    characters: [
      agent(10, 'spy', 'Shade', ME),
      agent(11, 'speaker', 'Voice', ME),
      agent(20, 'admiral', 'Raider', RIVAL),
      agent(21, 'spy', 'Lurker', RIVAL),
      agent(30, 'admiral', 'Friend', ALLY),
    ],
    bodies: [],
    ...extra,
  };
}

test('ownership is worked out from the viewer', () => {
  assert.equal(brief.relation(system(), player), 'own');
  assert.equal(brief.relation(system({ status: 'inhabited_dominion' }), player), 'own_dominion');
  assert.equal(brief.relation(system({ owner: ALLY }), player), 'faction');
  assert.equal(brief.relation(system({ owner: RIVAL }), player), 'enemy');
  assert.equal(brief.relation(system({ status: 'inhabited_neutral', owner: null }), player), 'autonomous');
  assert.equal(brief.relation(system({ contact: { value: 0 } }), player), 'unknown');
});

test('agents split into enemy / own / factionmates, own ones keep their roster', () => {
  const groups = brief.agentGroups(vm(), system());
  assert.deepEqual(groups.own.map((e) => e.character.name), ['Shade', 'Voice']);
  assert.deepEqual(groups.enemy.map((e) => e.character.name), ['Raider', 'Lurker']);
  assert.deepEqual(groups.faction.map((e) => e.character.name), ['Friend']);
  assert.equal(groups.own[0].roster.is_discovered, true);
  assert.equal(groups.enemy[0].roster, null);
});

test('a siege, an exposed own Erased and a visible enemy Erased are critical alerts, siege first', () => {
  const sys = system({ siege: { type: 'raid', besieger_id: 20, duration: 10, days: { value: 6 } } });
  const v = vm();
  const alerts = brief.criticalAlerts(v, sys, 'own', brief.agentGroups(v, sys), (t) => `${t} ticks`);
  assert.deepEqual(alerts.map((a) => a.text), [
    'Alert: Navarch Raider is bombarding this system, 6 ticks left',
    'Alert: your Erased Shade is exposed',
    'Enemy Erased Lurker is exposed here',
  ]);
});

test('a Siderian taking your dominion names the Siderians present', () => {
  const sys = system({
    status: 'inhabited_dominion',
    characters: [agent(22, 'speaker', 'Silver', RIVAL)],
  });
  const v = vm({ player: { dominions_under_attack: [7] } });
  const alerts = brief.criticalAlerts(v, sys, 'own_dominion', brief.agentGroups(v, sys), () => '');
  assert.equal(alerts[0].text, 'Alert: Siderian Silver is taking control of this dominion');
});

test('own systems flag an empty queue and a workforce shortage; enemy systems do not', () => {
  const v = vm();
  assert.deepEqual(brief.attention(v, system(), 'own').map((a) => a.key), ['queue', 'workforce']);
  assert.deepEqual(brief.attention(v, system(), 'enemy'), []);
  assert.match(brief.attention(v, system(), 'own')[1].text, /need 9, 8 available, output down 11%/);
});

test('the lead reads system, alerts, agents, then what needs doing', () => {
  const v = vm();
  const sys = system();
  const groups = brief.agentGroups(v, sys);
  const text = brief.lead(v, {
    heading: brief.title(v, sys, 'own'),
    alerts: brief.criticalAlerts(v, sys, 'own', groups, () => ''),
    attentionItems: brief.attention(v, sys, 'own'),
    groups,
    rel: 'own',
  });
  assert.ok(text.startsWith('Khesia, your system. Alert: your Erased Shade is exposed.'), text);
  assert.ok(text.includes('2 enemy agents, 2 of yours, 1 factionmate'), text);
  assert.ok(text.endsWith('Construction queue empty. Workforce short: buildings need 9, 8 available, output down 11%.'), text);
});

test('your resting Siderian says so; an enemy Erased is exposed', () => {
  const v = vm();
  const sys = system();
  const groups = brief.agentGroups(v, sys);
  assert.match(brief.agentLine(v, groups.own[1], sys), /Siderian Voice, level 3, Awaiting orders, resting/);
  assert.equal(brief.agentLine(v, groups.enemy[1], sys), 'Erased Lurker, level 4, Rival, Cardan, exposed');
});

test('bodies list planets before moons and asteroids, and skip tile-less hosts', () => {
  const tile = { id: 1, type: 'normal', building_status: 'empty', building_key: null, construction_status: 'none' };
  const sys = system({
    bodies: [
      { uid: 'g', name: 'Giant', type: 'gaseous_giant', tiles: [], bodies: [{ uid: 'm', name: 'Moon', type: 'moon', tiles: [tile], bodies: [] }] },
      { uid: 'p', name: 'Rock', type: 'sterile_planet', tiles: [tile], bodies: [] },
      { uid: 'b', name: 'Belt', type: 'asteroid_belt', tiles: [], bodies: [{ uid: 'a', name: 'Rocklet', type: 'asteroid', tiles: [tile], bodies: [] }] },
      { uid: 'h', name: 'Home', type: 'habitable_planet', tiles: [tile], bodies: [] },
    ],
  });
  assert.deepEqual(brief.bodies(sys).map((b) => b.uid), ['h', 'p', 'm', 'a']);
});

test('a tile reads its slot, building, level and state', () => {
  const v = vm();
  assert.equal(
    brief.tileLine(v, { id: 2, type: 'normal', building_status: 'damaged', building_key: 'mine_orbital', building_level: 2, construction_status: 'repair' }, 1),
    `Slot 2: ${messages.data.building.mine_orbital.name} level 2, damaged, Repairs underway`,
  );
  assert.equal(
    brief.tileLine(v, { id: 1, type: 'infrastructure', building_status: 'empty', building_key: null, construction_status: 'none' }, 0),
    'Slot 1, infrastructure slot: empty',
  );
});

test('building bonuses read as amounts, per-factor ones with the value here', () => {
  const v = vm();
  const text = brief.bonusText(v, [
    { type: 'add', value: 6, from: 'direct', to: 'sys_habitation' },
    { type: 'add', value: 2, from: 'body_ind', to: 'sys_production' },
  ], { industrial_factor: 4 }, null);
  assert.match(text, /^\+6 .+, \+2 .+ per point of .+ \(4 here\)$/);
});

test('a building\'s contribution sums its entries across the stat breakdowns', () => {
  const v = vm();
  const sys = system({
    production: { value: 50, details: { building: [{ reason: 'mine_orbital', value: 12 }, { reason: 'mine_orbital', value: 8 }] } },
    happiness: { value: 3, details: { building: [{ reason: 'mine_orbital', value: -1 }] } },
  });
  assert.equal(brief.contribution(v, sys, 'mine_orbital'), '20 Production, -1 Stability');
});
