// Sector card model — plain node, no webpack:
//   node --test front/src/game/map/__tests__/sector-summary.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { controlBar, factionStats, sectorCensus, sectorFactions } from '../sector-summary.js';

function sector(owner, division, extra = {}) {
  return { id: 3, owner, division, ...extra };
}

test('two factions: the line is the middle of the bar, the holder leads past it', () => {
  const bar = controlBar(sector('tetrarchy', [
    { faction: 'tetrarchy', points: 6 },
    { faction: 'cardan', points: 4 },
  ]));

  assert.deepEqual(bar.segments.map((s) => [s.faction, s.role]), [['tetrarchy', 'holder'], ['cardan', 'challenger']]);
  assert.equal(bar.line, 0.5);
  assert.equal(bar.segments[0].share, 0.6);
  assert.equal(bar.lead, 2);
});

test('the holder comes first even when a rival has more systems', () => {
  const bar = controlBar(sector('tetrarchy', [
    { faction: 'cardan', points: 5 },
    { faction: 'tetrarchy', points: 3 },
  ]));

  assert.equal(bar.holder.faction, 'tetrarchy');
  assert.equal(bar.challenger.faction, 'cardan');
  assert.equal(bar.lead, -2);
  // the marker (0.375) is short of the line (0.5): the sector is flipping
  assert.ok(bar.segments[0].share < bar.line);
});

test('with three factions the line sits between the holder and its strongest rival', () => {
  const bar = controlBar(sector('ark', [
    { faction: 'ark', points: 4 },
    { faction: 'synelle', points: 2 },
    { faction: 'myrmezir', points: 2 },
    { faction: null, points: 2 },
  ]));

  assert.equal(bar.total, 10);
  assert.equal(bar.challenger.points, 2);
  // (4 + 2) / 2 systems into a 10-system bar
  assert.ok(Math.abs(bar.line - 0.3) < 1e-9);
  assert.deepEqual(bar.segments.map((s) => s.role), ['holder', 'challenger', 'other', 'other']);
});

test('a tie keeps the holder: the marker sits on the line', () => {
  const bar = controlBar(sector('ark', [
    { faction: 'ark', points: 3 },
    { faction: 'cardan', points: 3 },
  ]));

  assert.equal(bar.lead, 0);
  assert.equal(bar.segments[0].share, bar.line);
});

test('neutral systems hold an unclaimed sector and can be the rival', () => {
  const unclaimed = controlBar(sector(null, [
    { faction: null, points: 4 },
    { faction: 'cardan', points: 2 },
  ]));
  assert.equal(unclaimed.holder.faction, null);
  assert.equal(unclaimed.challenger.faction, 'cardan');

  const pressed = controlBar(sector('cardan', [
    { faction: null, points: 4 },
    { faction: 'cardan', points: 2 },
  ]));
  assert.equal(pressed.challenger.faction, null);
  assert.equal(pressed.lead, -2);
});

test('in a start sector the neutral systems are not a rival', () => {
  const bar = controlBar(sector('cardan', [
    { faction: null, points: 4 },
    { faction: 'cardan', points: 2 },
    { faction: 'ark', points: 1 },
  ], { 'starter?': true }));

  assert.equal(bar.challenger.faction, 'ark');
  assert.equal(bar.lead, 1);
  assert.deepEqual(bar.segments.map((s) => s.faction), ['cardan', 'ark', null]);
});

test('a holder alone has no line', () => {
  const bar = controlBar(sector('ark', [{ faction: 'ark', points: 3 }]));

  assert.equal(bar.challenger, null);
  assert.equal(bar.line, null);
  assert.equal(bar.lead, null);
});

test('a holder with no system left there still heads the bar', () => {
  const bar = controlBar(sector('ark', [{ faction: 'cardan', points: 2 }]));

  assert.equal(bar.holder.points, 0);
  assert.equal(bar.holder.share, 0);
  assert.equal(bar.lead, -2);
});

test('an empty sector gives an empty bar', () => {
  const bar = controlBar(sector(null, []));

  assert.equal(bar.total, 0);
  assert.equal(bar.line, null);
});

const systems = [
  { id: 1, sector_id: 3, faction: 'ark', owner: 'Ada', class: 'big', visibility: 5 },
  { id: 2, sector_id: 3, faction: 'ark', owner: 'Bo', class: 'small', visibility: 5 },
  { id: 3, sector_id: 3, faction: 'cardan', owner: 'Cy', class: 'big', visibility: 3 },
  { id: 4, sector_id: 3, faction: 'cardan', owner: 'Cy', class: 'small', visibility: 0 },
  // neutral: no population points for us, nothing to earn in visibility
  { id: 5, sector_id: 3, faction: null, owner: null, class: 'small', visibility: 2 },
  { id: 6, sector_id: 9, faction: 'ark', owner: 'Ada', class: 'big', visibility: 5 },
];
const pointsByClass = { small: 1, big: 4 };

const stats = (faction, intel = null, sectorId = 3) => factionStats({
  sectorId, systems, faction, ownFaction: 'ark', pointsByClass, intel,
});

test('the viewer faction: population of its systems, visibility on everyone else', () => {
  const own = stats('ark');

  assert.equal(own.own, true);
  assert.equal(own.systems, 2);
  assert.deepEqual(own.population, { points: 5, systems: 2 });
  assert.deepEqual(own.visibility, { points: 3, max: 10 });
  assert.equal(own.economy, null);
});

test('visibility is not shown where no other faction holds a system', () => {
  assert.equal(stats('ark', null, 9).visibility, null);
});

test('another faction: only what the contact on each system shows', () => {
  const cardan = stats('cardan');

  assert.equal(cardan.own, false);
  assert.equal(cardan.systems, 2);
  // one system at contact 3 (its class counts), one at 0 (it does not)
  assert.deepEqual(cardan.population, { points: 4, systems: 1 });
  // the viewer's contact on that faction's two systems
  assert.deepEqual(cardan.visibility, { points: 3, max: 10 });
  assert.equal(cardan.foreignFleets, null);
});

const intel = {
  systems: {
    1: {
      sector_id: 3,
      agents: [
        { id: 1, type: 'admiral', faction: 'ark', upkeep: 900 },
        { id: 2, type: 'admiral', faction: 'ark', upkeep: 300 },
        { id: 3, type: 'spy', faction: 'ark', upkeep: null },
        { id: 4, type: 'admiral', faction: 'cardan', upkeep: null },
        { id: 7, type: 'admiral', faction: 'cardan', upkeep: 2000 },
      ],
    },
    6: { sector_id: 9, agents: [{ id: 5, type: 'admiral', faction: 'ark', upkeep: 100 }] },
  },
  sectors: {
    3: {
      ark: { id: 3, faction: 'ark', systems: 2, technology: 10, ideology: 5, credit: 120 },
      cardan: { id: 3, faction: 'cardan', systems: 1, technology: 2, ideology: 1, credit: 40 },
    },
  },
};

test('fleets and income come from the map intel of that sector', () => {
  const own = stats('ark', intel);

  assert.deepEqual(own.fleets, { count: 2, upkeep: 1200, unread: 0 });
  assert.equal(own.foreignFleets, 2);
  assert.equal(own.economy.credit, 120);
});

test('another faction fleets: those in sight, upkeep where it can be read', () => {
  const cardan = stats('cardan', intel);

  assert.deepEqual(cardan.fleets, { count: 2, upkeep: 2000, unread: 1 });
  // income of the one system read, out of the two it holds
  assert.equal(cardan.economy.systems, 1);
  assert.equal(cardan.systems, 2);
});

test('the card pages through the viewer, then the holder, then the rest by size', () => {
  const sector = {
    owner: 'cardan',
    division: [
      { faction: null, points: 9 },
      { faction: 'synelle', points: 5 },
      { faction: 'cardan', points: 4 },
      { faction: 'ark', points: 2 },
      { faction: 'myrmezir', points: 1 },
    ],
  };

  assert.deepEqual(sectorFactions(sector, 'ark'), ['ark', 'cardan', 'synelle', 'myrmezir']);
  // the viewer comes first even with nothing there
  assert.deepEqual(sectorFactions({ owner: null, division: [{ faction: 'cardan', points: 1 }] }, 'ark'), ['ark', 'cardan']);
});

test('the census sums the built Cyber Commands of the sector', () => {
  const government = {
    station_powered: true,
    station_buildings: [
      { key: 'cyber_command', status: 'built', sector_id: 3, census: 4 },
      { key: 'cyber_command', status: 'built', sector_id: 3, census: 3 },
      { key: 'cyber_command', status: 'disabled', sector_id: 3, census: 9 },
      { key: 'cyber_command', status: 'built', sector_id: 4, census: 8 },
      { key: 'gateway', status: 'built', sector_id: 3 },
    ],
  };

  assert.deepEqual(sectorCensus(government, 3), { commands: 2, count: 7, powered: true });
  assert.equal(sectorCensus(government, 5), null);
  assert.equal(sectorCensus(null, 3), null);
  assert.equal(sectorCensus({ ...government, station_powered: false }, 3).powered, false);
});
