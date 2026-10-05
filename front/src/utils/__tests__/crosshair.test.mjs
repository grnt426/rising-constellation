// Galaxy crosshair settings and geometry — plain node, no webpack:
//   node --test front/src/utils/__tests__/crosshair.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_CROSSHAIR, SIZE_LIMITS, normalizeHex, normalizeCrosshair, isDefaultCrosshair,
  crosshairColor, crosshairMarks, crosshairExtent, hsvToHex, hexToHsv,
} from '../crosshair.js';
import { FACTIONS } from '../factions.js';

const box = ({ left, top, width, height }) => [left, top, left + width, top + height];

test('an account that never touched the setting gets the original crosshair', () => {
  [undefined, null, {}, 'nope', []].forEach((saved) => {
    assert.deepEqual(normalizeCrosshair(saved), { ...DEFAULT_CROSSHAIR });
  });
  assert.equal(isDefaultCrosshair(undefined), true);
  assert.equal(isDefaultCrosshair({ dot: true }), false);
});

test('the default draws the four black lines the map always had', () => {
  const marks = crosshairMarks(normalizeCrosshair());

  // The old stylesheet: 2px bars from 20px to 100px left and right of the
  // center, and from 20px to 50px above and below it.
  assert.deepEqual(marks.map(box), [
    [-100, -1, -20, 1],
    [20, -1, 100, 1],
    [-1, -50, 1, -20],
    [-1, 20, 1, 50],
  ]);
  assert.ok(marks.every((mark) => mark.type === 'line'));
  assert.equal(crosshairColor(normalizeCrosshair(), null), '#000000');
});

test('lines, circle and dot combine freely', () => {
  const only = (flags) => crosshairMarks(normalizeCrosshair({
    cross: false, circle: false, dot: false, ...flags,
  })).map((mark) => mark.type);

  assert.deepEqual(only({ circle: true }), ['circle']);
  assert.deepEqual(only({ dot: true }), ['dot']);
  assert.deepEqual(only({ circle: true, dot: true }), ['circle', 'dot']);
  assert.deepEqual(
    only({ cross: true, circle: true, dot: true }),
    ['line', 'line', 'line', 'line', 'circle', 'dot'],
  );
});

test('with every mark off nothing is drawn', () => {
  const none = normalizeCrosshair({ cross: false, circle: false, dot: false });

  assert.deepEqual(crosshairMarks(none), []);
  assert.deepEqual(crosshairExtent(none), { x: 0, y: 0 });
});

test('line lengths are independent, and a length of 0 drops that pair', () => {
  const wide = crosshairMarks(normalizeCrosshair({ width: 200, height: 0 }));
  assert.deepEqual(wide.map(box), [[-220, -1, -20, 1], [20, -1, 220, 1]]);

  const tall = crosshairMarks(normalizeCrosshair({ width: 0, height: 120 }));
  assert.deepEqual(tall.map(box), [[-1, -140, 1, -20], [-1, 20, 1, 140]]);
});

test('circle and dot are centered on the map center', () => {
  const marks = crosshairMarks(normalizeCrosshair({
    cross: false, circle: true, dot: true, circle_size: 60, dot_size: 8,
  }));

  assert.deepEqual(marks.map(box), [[-30, -30, 30, 30], [-4, -4, 4, 4]]);
});

test('the extent covers the farthest mark on each axis', () => {
  assert.deepEqual(crosshairExtent(normalizeCrosshair()), { x: 100, y: 50 });
  assert.deepEqual(
    crosshairExtent(normalizeCrosshair({ circle: true, circle_size: 240 })),
    { x: 120, y: 120 },
  );
});

test('sizes are clamped to their range and kept even', () => {
  const c = normalizeCrosshair({
    width: 9999, height: -5, circle_size: 1, dot_size: '7', color: 'nonsense',
  });

  assert.equal(c.width, SIZE_LIMITS.width.max);
  assert.equal(c.height, 0);
  assert.equal(c.circle_size, SIZE_LIMITS.circle_size.min);
  assert.equal(c.dot_size, 8);
  assert.equal(c.color, DEFAULT_CROSSHAIR.color);

  assert.equal(normalizeCrosshair({ width: NaN }).width, DEFAULT_CROSSHAIR.width);
  assert.equal(normalizeCrosshair({ cross: 'yes' }).cross, DEFAULT_CROSSHAIR.cross);
});

test('hex codes are accepted in the usual spellings', () => {
  assert.equal(normalizeHex('#3F66DF'), '#3f66df');
  assert.equal(normalizeHex('3f66df'), '#3f66df');
  assert.equal(normalizeHex(' #abc '), '#aabbcc');
  assert.equal(normalizeHex('#12345'), null);
  assert.equal(normalizeHex('red'), null);
  assert.equal(normalizeHex(undefined), null);
});

test('matching the faction uses its color in a match and the chosen one outside', () => {
  const custom = normalizeCrosshair({ color: '#ff00ff' });
  const matching = normalizeCrosshair({ color: '#ff00ff', match_faction: true });

  assert.equal(crosshairColor(custom, '#3f66df'), '#ff00ff');
  assert.equal(crosshairColor(matching, '#3f66df'), '#3f66df');
  assert.equal(crosshairColor(matching, null), '#ff00ff');
  assert.equal(crosshairColor(matching, 'not a color'), '#ff00ff');
});

test('the wheel reaches every faction color and gives it back unchanged', () => {
  FACTIONS.forEach(({ color }) => {
    assert.equal(hsvToHex(hexToHsv(color)), color);
  });

  ['#000000', '#ffffff', '#808080', '#ff0000', '#00ff00', '#0000ff', '#12ab9c'].forEach((hex) => {
    assert.equal(hsvToHex(hexToHsv(hex)), hex);
  });
});

test('hue, saturation and value map to the expected colors', () => {
  assert.equal(hsvToHex({ h: 0, s: 1, v: 1 }), '#ff0000');
  assert.equal(hsvToHex({ h: 120, s: 1, v: 1 }), '#00ff00');
  assert.equal(hsvToHex({ h: 240, s: 1, v: 1 }), '#0000ff');
  assert.equal(hsvToHex({ h: 360, s: 1, v: 1 }), '#ff0000');
  assert.equal(hsvToHex({ h: -120, s: 1, v: 1 }), '#0000ff');
  assert.equal(hsvToHex({ h: 200, s: 0, v: 1 }), '#ffffff');
  assert.equal(hsvToHex({ h: 200, s: 1, v: 0 }), '#000000');

  assert.deepEqual(hexToHsv('#ff0000'), { h: 0, s: 1, v: 1 });
  assert.deepEqual(hexToHsv('#000000'), { h: 0, s: 0, v: 0 });
});
