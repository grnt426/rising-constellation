// Overview-mode glyph model — plain node, no webpack:
//   node --test front/src/game/map/__tests__/system-glyph.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  FLEET_CAP, MAX_PIPS, presence, fleetArcs, agentPips, statIcons, statRows, statLayout, glyphRadii, glyphScale,
} from '../system-glyph.js';

const TAU = Math.PI * 2;
const close = (a, b) => Math.abs(a - b) < 1e-9;

test('the viewer own agents come from the live roster, not from the intel', () => {
  const result = presence({
    intelAgents: [
      // the intel still shows my fleet here, and at an old strength
      { id: 1, type: 'admiral', faction: 'ark', upkeep: 500 },
      { id: 2, type: 'admiral', faction: 'cardan', upkeep: null },
      { id: 3, type: 'spy', faction: 'ark', upkeep: null },
    ],
    liveAgents: [{ id: 4, type: 'admiral', faction: 'ark', upkeep: 900 }],
    playerAgentIds: new Set([1, 4]),
    ownFaction: 'ark',
  });

  assert.deepEqual(result.fleets.map((f) => [f.id, f.mine]), [[4, true], [2, false]]);
  assert.deepEqual(result.agents.map((a) => a.id), [3]);
});

test('fleets are ordered mine, my faction, then the others', () => {
  const { fleets } = presence({
    intelAgents: [
      { id: 2, type: 'admiral', faction: 'cardan', upkeep: 4000 },
      { id: 3, type: 'admiral', faction: 'ark', upkeep: 100 },
      { id: 5, type: 'admiral', faction: 'ark', upkeep: 700 },
    ],
    liveAgents: [{ id: 4, type: 'admiral', faction: 'ark', upkeep: 50 }],
    playerAgentIds: new Set([4]),
    ownFaction: 'ark',
  });

  assert.deepEqual(fleets.map((f) => f.id), [4, 5, 3, 2]);
});

test('a fleet arc is as long as its share of the cap', () => {
  const [arc] = fleetArcs([{ faction: 'ark', upkeep: FLEET_CAP / 4, mine: true }]);

  assert.equal(arc.start, 0);
  assert.ok(close(arc.sweep, TAU / 4));
  assert.equal(arc.known, true);
  assert.equal(arc.mine, true);
});

test('arcs follow each other clockwise with a gap between them', () => {
  const arcs = fleetArcs([
    { faction: 'ark', upkeep: 2000 },
    { faction: 'cardan', upkeep: 2000 },
  ]);

  assert.ok(arcs[1].start > arcs[0].start + arcs[0].sweep);
  assert.ok(close(arcs[0].sweep, arcs[1].sweep));
});

test('a small fleet keeps a visible arc, an unread one gets a fixed arc', () => {
  const [small, unread] = fleetArcs([
    { faction: 'ark', upkeep: 10 },
    { faction: 'cardan', upkeep: null },
  ]);

  assert.ok(small.sweep > 0.2);
  assert.equal(unread.known, false);
  assert.ok(unread.sweep > small.sweep);
});

test('past a full ring the arcs shrink together and still fit', () => {
  const arcs = fleetArcs([
    { faction: 'ark', upkeep: 6000 },
    { faction: 'ark', upkeep: 6000 },
    { faction: 'cardan', upkeep: 12000 },
  ]);
  const last = arcs[arcs.length - 1];

  assert.ok(last.start + last.sweep <= TAU + 1e-9);
  // shares are kept: the 12k fleet is still twice a 6k one
  assert.ok(close(arcs[2].sweep, arcs[0].sweep * 2));
});

test('no fleet, no arc', () => {
  assert.deepEqual(fleetArcs([]), []);
});

test('pips fan out around 6 o clock and stop at the cap', () => {
  const one = agentPips([{ faction: 'ark', type: 'spy' }]);
  assert.ok(close(one[0].angle, Math.PI));

  const two = agentPips([{ faction: 'ark', type: 'spy' }, { faction: 'ark', type: 'speaker' }]);
  assert.ok(close((two[0].angle + two[1].angle) / 2, Math.PI));
  assert.ok(two[0].angle < two[1].angle);

  const many = agentPips(Array.from({ length: 12 }, () => ({ faction: 'ark', type: 'spy' })));
  assert.equal(many.length, MAX_PIPS);
});

const shapes = (value) => statIcons(value).map((icon) => [icon.large ? 'L' : 's', Math.round(icon.fill * 100)]);

test('a large icon is worth 100, a small one 50, the last filled as far as it goes', () => {
  assert.deepEqual(shapes(257), [['L', 100], ['L', 100], ['s', 100], ['s', 14]]);
  assert.deepEqual(shapes(100), [['L', 100]]);
  assert.deepEqual(shapes(150), [['L', 100], ['s', 100]]);
  assert.deepEqual(shapes(30), [['s', 60]]);
  assert.deepEqual(shapes(120), [['L', 100], ['s', 40]]);
});

test('a stat at zero is one empty small icon', () => {
  assert.deepEqual(statIcons(0), [{ large: false, fill: 0, broken: false }]);
});

test('negative stability reads on its size, with broken icons', () => {
  const icons = statIcons(-175);

  assert.deepEqual(icons.map((icon) => icon.large), [true, false, false]);
  assert.ok(icons.every((icon) => icon.broken));
  assert.ok(close(icons[2].fill, 0.5));
});

test('a sliver is dropped, and the icons stop at 500', () => {
  assert.deepEqual(shapes(101), [['L', 100]]);
  assert.deepEqual(shapes(152), [['L', 100], ['s', 100]]);
  assert.deepEqual(shapes(40000), [['L', 100], ['L', 100], ['L', 100], ['L', 100], ['L', 100]]);
});

test('a stat the intel does not carry has no icons', () => {
  assert.deepEqual(statIcons(null), []);
  assert.deepEqual(statIcons(undefined), []);
});

test('stat rows are for the faction own systems only', () => {
  const rows = statRows({ own: true, defense: 160, stability: -10, counter_intelligence: null });

  assert.deepEqual(rows.map((row) => [row.key, row.icons.length]), [['defense', 3], ['stability', 1]]);
  assert.equal(rows[1].icons[0].broken, true);
  assert.deepEqual(statRows({ own: false, defense: 60 }), []);
  assert.deepEqual(statRows(undefined), []);
});

const angleOf = (icon) => {
  const a = Math.atan2(icon.x, icon.y);
  return ((a < 0 ? a + TAU : a) * 180) / Math.PI;
};
const rowsFor = (defense, stability, intelligence) => statRows({
  own: true, defense, stability, counter_intelligence: intelligence,
});
const RADIUS = glyphRadii(1, true).statRadius;

test('each stat keeps to its third of one shared ring', () => {
  const icons = statLayout(rowsFor(499, 499, 499), RADIUS);

  icons.forEach((icon) => assert.ok(close(Math.hypot(icon.x, icon.y), RADIUS)));
  const within = (key, from, to) => icons
    .filter((icon) => icon.key === key)
    .every((icon) => angleOf(icon) > from && angleOf(icon) < to);
  assert.ok(within('stability', 0, 120));
  assert.ok(within('defense', 120, 240));
  assert.ok(within('counter_intelligence', 240, 360));
});

test('the upper stats start at the top and run down their side, large icons first', () => {
  const icons = statLayout(rowsFor(null, 257, 257), RADIUS);
  const stability = icons.filter((icon) => icon.key === 'stability');
  const intelligence = icons.filter((icon) => icon.key === 'counter_intelligence');

  assert.ok(angleOf(stability[0]) < 25);
  assert.ok(stability.every((icon, i) => i === 0 || angleOf(icon) > angleOf(stability[i - 1])));
  assert.ok(angleOf(intelligence[0]) > 335);
  assert.ok(intelligence.every((icon, i) => i === 0 || angleOf(icon) < angleOf(intelligence[i - 1])));
  // two large, then two small: the large ones are drawn larger
  assert.ok(stability[0].size > stability[2].size);
  assert.ok(close(stability[0].size, stability[1].size));
  assert.ok(close(stability[3].fill, 0.14));
});

test('defense is centred under the system and reads left to right', () => {
  const icons = statLayout(rowsFor(300, null, null), RADIUS);

  assert.ok(icons.every((icon) => icon.y < 0));
  assert.ok(close(icons[1].x, 0));
  assert.ok(icons[0].x < icons[1].x && icons[1].x < icons[2].x);
});

test('four large icons fit a third at full size', () => {
  const full = statLayout(rowsFor(100, null, null), RADIUS)[0].size;
  const four = statLayout(rowsFor(400, 100, 50), RADIUS);

  assert.ok(four.filter((icon) => icon.key === 'defense').every((icon) => close(icon.size, full)));
});

test('a stat that needs more room shrinks every icon of the system together', () => {
  const full = statLayout(rowsFor(100, null, null), RADIUS)[0].size;
  const icons = statLayout(rowsFor(480, 100, 50), RADIUS);
  const defense = icons.filter((icon) => icon.key === 'defense');
  const stability = icons.filter((icon) => icon.key === 'stability');

  assert.equal(defense.length, 6);
  assert.ok(defense[0].size < full);
  // the short rows shrink with it: a large icon is one size everywhere
  assert.ok(close(stability[0].size, defense[0].size));
  // and the long row still keeps to its third without overlapping
  assert.ok(defense.every((icon) => angleOf(icon) > 120 && angleOf(icon) < 240));
  for (let i = 1; i < defense.length; i += 1) {
    const gap = Math.hypot(defense[i].x - defense[i - 1].x, defense[i].y - defense[i - 1].y);
    assert.ok(gap >= ((defense[i].size + defense[i - 1].size) / 2) * 0.98);
  }
});

test('the stat ring hugs the pips, and a held system reaches out to it', () => {
  const plain = glyphRadii(1);
  const held = glyphRadii(1, true);

  assert.ok(held.statRadius < plain.pipOrbit + 0.3);
  assert.ok(held.statRadius > plain.pipOrbit + plain.pipRadius);
  assert.ok(held.extent > held.statRadius);
  assert.ok(held.extent > plain.extent);
});

test('the glyph is drawn to scale up close and grows in steps with altitude', () => {
  assert.equal(glyphScale(26), 1);
  assert.equal(glyphScale(36), 1);
  assert.equal(glyphScale(72), 2);
  assert.equal(glyphScale(500), 2.75);
  assert.equal((glyphScale(50) * 4) % 1, 0);
});
