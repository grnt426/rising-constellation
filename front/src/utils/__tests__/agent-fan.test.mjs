// Squadron unfurl layout — plain node, no webpack:
//   node --test front/src/utils/__tests__/agent-fan.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ICON, ACTION, unfurlLayout, unfurlBandPaths, badgeLeft,
} from '../agent-fan.js';

// The system view (.system-content) on a 1440×900, a 1920×1080 and a
// 1280×720 screen, as measured in the game.
const VIEWS = [
  { width: 892, height: 792 },
  { width: 1072, height: 972 },
  { width: 712, height: 612 },
];
// slot angles the outer fan hands out: center, ends, besieger
const ANGLES = [0, 13.5, -30, 45, -58, 58, -64];

// the stack's position for a slot angle (orbitStyle: 40% ring)
function originOf(view, angle) {
  const rad = (angle * Math.PI) / 180;
  return {
    x: (view.width / 2) + (Math.cos(rad) * 0.4 * view.width),
    y: (view.height / 2) + (Math.sin(rad) * 0.4 * view.height),
  };
}

function areaOf(view) {
  return { left: 0, top: 0, right: view.width, bottom: view.height };
}

function squad(count, actions, armadas = []) {
  const members = Array.from({ length: count }, () => ({ actions, group: null }));
  let at = 0;
  armadas.forEach((size, i) => {
    for (let k = 0; k < size; k += 1) members[at + k].group = `a${i}`;
    at += size;
  });
  return members;
}

// a badge's box: icon plus its action buttons to the left
function footprint(cell, actions) {
  return {
    left: cell.x + badgeLeft(actions),
    right: cell.x + (ICON / 2),
    top: cell.y - (ICON / 2),
    bottom: cell.y + (ICON / 2),
  };
}

function overlaps(a, b) {
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}

test('badgeLeft matches the toolbox CSS: buttons end 17px left of the icon center', () => {
  assert.equal(badgeLeft(0), -ICON / 2);
  assert.equal(badgeLeft(1), -(17 + ACTION));
  assert.equal(badgeLeft(2), -(17 + (2 * ACTION)));
});

test('no two badges overlap, whatever the size, button count and slot', () => {
  VIEWS.forEach((view) => {
    ANGLES.forEach((angle) => {
      for (let actions = 0; actions <= 2; actions += 1) {
        for (let count = 2; count <= 40; count += 1) {
          const members = squad(count, actions);
          const { cells } = unfurlLayout(members, { angle, origin: originOf(view, angle), areas: [areaOf(view)] });
          const boxes = cells.map((c) => footprint(c, actions));

          for (let i = 0; i < boxes.length; i += 1) {
            for (let j = i + 1; j < boxes.length; j += 1) {
              assert.ok(
                !overlaps(boxes[i], boxes[j]),
                `${count} members, ${actions} buttons, angle ${angle}, view ${view.width}: ${i} and ${j} overlap`,
              );
            }
          }
        }
      }
    });
  });
});

test('badges never cover the stack they unfurl from', () => {
  // the stack's icon plus its ghost icons up-right
  const stack = { left: -ICON / 2, right: (ICON / 2) + 14, top: -(ICON / 2) - 14, bottom: ICON / 2 };

  [2, 5, 9, 15, 30].forEach((count) => {
    ANGLES.forEach((angle) => {
      const view = VIEWS[0];
      const { cells } = unfurlLayout(squad(count, 2), { angle, origin: originOf(view, angle), areas: [areaOf(view)] });
      cells.forEach((c, i) => assert.ok(!overlaps(footprint(c, 2), stack), `member ${i} of ${count} covers the stack`));
    });
  });
});

test('the tray holds every badge and reaches the stack, but not past it', () => {
  const view = VIEWS[0];
  ANGLES.forEach((angle) => {
    [2, 5, 15].forEach((count) => {
      const { cells, tray } = unfurlLayout(squad(count, 2), { angle, origin: originOf(view, angle), areas: [areaOf(view)] });
      cells.forEach((c) => {
        const b = footprint(c, 2);
        assert.ok(b.left >= tray.left && b.right <= tray.left + tray.width, 'badge outside the tray horizontally');
        assert.ok(b.top >= tray.top && b.bottom <= tray.top + tray.height, 'badge outside the tray vertically');
      });
      const right = tray.left + tray.width;
      // tucked under the stack icon's left edge; its neighbours on the
      // ring (directly above and below it) stay uncovered
      assert.ok(right > -ICON / 2 && right < 0, `tray right edge at ${right}`);
    });
  });
});

test('a ZURKA-sized squadron (15, two buttons each) stays inside a 1440×900 system view', () => {
  const view = VIEWS[0];
  ANGLES.forEach((angle) => {
    const origin = originOf(view, angle);
    const { tray } = unfurlLayout(squad(15, 2), { angle, origin, areas: [areaOf(view)] });
    assert.ok(origin.x + tray.left >= 0, `angle ${angle}: tray leaves the view on the left`);
    assert.ok(origin.y + tray.top >= 0, `angle ${angle}: tray leaves the view on top`);
    assert.ok(origin.y + tray.top + tray.height <= view.height, `angle ${angle}: tray leaves the view at the bottom`);
  });
});

test('the first members take the column nearest the stack, top to bottom', () => {
  const { cells } = unfurlLayout(squad(15, 2), { angle: 0, origin: originOf(VIEWS[0], 0), areas: [areaOf(VIEWS[0])] });
  assert.deepEqual(cells.slice(0, 5).map((c) => c.col), [0, 0, 0, 0, 0]);
  assert.ok(cells.slice(0, 5).every((c, i, all) => i === 0 || c.y > all[i - 1].y));
  assert.ok(cells[5].x < cells[0].x, 'second column sits further from the stack');
  // three columns of five
  assert.equal(new Set(cells.map((c) => c.col)).size, 3);
});

test('small squadrons are a single column', () => {
  [2, 3, 4, 5].forEach((count) => {
    const { cells } = unfurlLayout(squad(count, 2), { angle: 0, origin: originOf(VIEWS[0], 0), areas: [areaOf(VIEWS[0])] });
    assert.ok(cells.every((c) => c.col === 0), `${count} members`);
  });
});

test('a stack high on the ring grows downward, one low on the ring upward', () => {
  const view = VIEWS[1];
  const high = unfurlLayout(squad(5, 1), { angle: -58, origin: originOf(view, -58), areas: [areaOf(view)] });
  const low = unfurlLayout(squad(5, 1), { angle: 58, origin: originOf(view, 58), areas: [areaOf(view)] });
  const mean = (cells) => cells.reduce((s, c) => s + c.y, 0) / cells.length;
  assert.ok(mean(high.cells) > 0);
  assert.ok(mean(low.cells) < 0);
});

test('armadas are never split across columns', () => {
  // 4 singles then two trios: the first trio would straddle column 0's end
  const members = [
    ...squad(4, 2),
    ...squad(6, 2, [3, 3]),
  ];
  members.forEach((m, i) => { if (i >= 4) m.group = i < 7 ? 'a' : 'b'; });
  const { cells } = unfurlLayout(members, { angle: 0, origin: originOf(VIEWS[0], 0), areas: [areaOf(VIEWS[0])] });

  ['a', 'b'].forEach((group) => {
    const cols = new Set(cells.filter((_, i) => members[i].group === group).map((c) => c.col));
    assert.equal(cols.size, 1, `armada ${group} spans ${cols.size} columns`);
  });

  const bands = [
    { groupId: 'a', indexes: [4, 5, 6] },
    { groupId: 'b', indexes: [7, 8, 9] },
  ];
  assert.equal(unfurlBandPaths(bands, cells).length, 2);
});

test('hover cards open below the icon near the top of the view', () => {
  // the 1280×720 view, where the besieger's slot sits 86px from the top
  const view = VIEWS[2];
  const origin = originOf(view, -64);
  const { cells } = unfurlLayout(squad(8, 2), { angle: -64, origin, areas: [areaOf(view)] });
  cells.forEach((c) => assert.equal(c.flip, origin.y + c.y < 100));
  assert.ok(cells.some((c) => c.flip));
});

test('the grid keeps to the first area it fits in, else takes the last', () => {
  // 1280×720 with the side panel over the view's left 276px and the
  // selected agent's panel over its bottom 191px
  const view = { width: 712, height: 612 };
  const origin = originOf(view, -6.75);
  const free = { left: 276, top: 0, right: view.width, bottom: 421 };
  const whole = areaOf(view);
  const inside = (layout, area) => origin.x + layout.tray.left >= area.left
    && origin.y + layout.tray.top >= area.top
    && origin.y + layout.tray.top + layout.tray.height <= area.bottom;

  const small = unfurlLayout(squad(8, 2), { angle: -6.75, origin, areas: [free, whole] });
  assert.ok(inside(small, free), 'eight members fit beside the panels');

  const big = unfurlLayout(squad(15, 2), { angle: -6.75, origin, areas: [free, whole] });
  assert.ok(!inside(big, free));
  assert.ok(inside(big, whole), 'fifteen members fall back to the whole view');
});

test('without a measured view it still lays out, unclamped', () => {
  const { cells, tray } = unfurlLayout(squad(12, 2), { angle: 20 });
  assert.equal(cells.length, 12);
  assert.ok(tray.width > 0 && tray.height > 0);
  assert.deepEqual(unfurlLayout([], {}), { cells: [], tray: null });
});
