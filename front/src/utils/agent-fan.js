// Squadron unfurl layout for the system view's fan display
// (Actions.vue, `agent_fan_display` beta).
//
// An unfurled squadron is a grid of rows, not a ring: every member badge
// drags its action buttons out to the LEFT of its icon (two buttons make
// it ~120px wide for a 50px icon), and only a grid gives each badge that
// whole footprint. Columns grow from the stack toward the system center,
// one footprint wide each; rows are one icon tall. The first members
// (highest rank and level) fill the column nearest the stack. A dark tray
// behind the grid sets the squadron apart from the planets and badges it
// covers while it is open.
//
// Pixel constants mirror styles/game/components/galaxy/system/actions.scss
// (`.system-actions .round-icon`, `.toolbox-actions`, `.actions-item`):
// keep the two in step.

export const ICON = 50; // member icon diameter
export const ACTION = 40; // action button diameter
// The toolbox ends at the icon's left edge and every button is shifted
// 8px right, so the buttons end 17px left of the icon center.
const ACTION_END = 17;
export const ROW_PITCH = 58; // icon + 8px
export const COL_GAP = 14;
export const TRAY_PAD = 10;
// how far the tray's edge runs under the stack's icon
const TUCK = 4;
// columns hold at most this many rows while the view has room for more
// columns, so a squadron spreads into a block rather than a tall strip
const PREFERRED_ROWS = 5;
// the tray stays this far inside the view
const MARGIN = 8;
// room the hover card needs above an icon center; with less, it opens below
const CARD_ROOM = 100;
// An action's success preview (ActionOverview, 200px plus its 20px
// margin) opens to the left of the badge's buttons and reaches this far
// past the leftmost one (the buttons themselves sit 8px right of their
// slots).
const PREVIEW_REACH = 212;
// band (formation capsule) radius around an armada member's icon
const BAND_RADIUS = 30;

// Left edge of a badge with `actionCount` buttons, relative to its icon
// center (the right edge is always ICON / 2).
export function badgeLeft(actionCount) {
  return actionCount > 0 ? -(ACTION_END + (ACTION * actionCount)) : -ICON / 2;
}

// Members of one armada are adjacent in the list (armadaUtil.groupAdjacent)
// and form one block, which is never split across two columns.
function blocks(members) {
  const out = [];

  members.forEach((member, index) => {
    const last = out[out.length - 1];
    if (member.group != null && last && last.group === member.group) {
      last.indexes.push(index);
    } else {
      out.push({ group: member.group, indexes: [index] });
    }
  });

  return out;
}

function pack(blockList, rows) {
  const slots = [];
  let col = 0;
  let row = 0;

  blockList.forEach((block) => {
    if (row > 0 && row + block.indexes.length > rows) {
      col += 1;
      row = 0;
    }
    block.indexes.forEach((index) => {
      slots[index] = { col, row };
      row += 1;
      if (row >= rows) {
        col += 1;
        row = 0;
      }
    });
  });

  return { slots, cols: row > 0 ? col + 1 : col };
}

// How many columns and rows of badges an area holds around the stack.
function capacity(area, origin, x0, left, colPitch) {
  const room = origin.x + x0 + left - TRAY_PAD - MARGIN - area.left;
  const height = area.bottom - area.top - (2 * (MARGIN + TRAY_PAD)) - ICON;
  return {
    cols: Math.max(1, 1 + Math.floor(room / colPitch)),
    rows: Math.max(1, 1 + Math.floor(height / ROW_PITCH)),
  };
}

// members: [{ actions: <button count>, group: <armada id or null> }] in
// display order. angle: the stack's slot angle in degrees (0 = due right
// of the system center, negative = upper half). origin: the stack's
// position in px. areas: where the grid may go, as { left, top, right,
// bottom } rects in the same frame as origin, best first: the grid takes
// the first one it fits in, else the last. Without origin and areas the
// grid isn't kept anywhere in particular.
//
// Returns, relative to the stack's center:
//   cells: [{ x, y, col, row, flip, previewRight }] (flip: open the
//          hover card below; previewRight: open action success previews
//          right of the icon)
//   tray:  { left, top, width, height }, the grid's backdrop
export function unfurlLayout(members, { angle = 0, origin = null, areas = [] } = {}) {
  const count = members.length;
  if (count === 0) return { cells: [], tray: null };

  const left = badgeLeft(Math.max(...members.map((m) => m.actions || 0)));
  const colPitch = (ICON / 2) - left + COL_GAP;
  // the nearest column clears the stack's own icon
  const x0 = -(ICON + COL_GAP);

  let area = null;
  let maxCols = Infinity;
  if (origin && areas.length > 0) {
    area = areas.find((a) => {
      const fit = capacity(a, origin, x0, left, colPitch);
      return fit.cols * fit.rows >= count;
    }) || areas[areas.length - 1];
    maxCols = capacity(area, origin, x0, left, colPitch).cols;
  }

  const blockList = blocks(members);
  const cols = Math.min(Math.ceil(count / PREFERRED_ROWS), maxCols);
  let rows = Math.ceil(count / cols);
  let packed = pack(blockList, rows);
  // an armada block that doesn't fit a column's remaining rows starts the
  // next column, which can make the grid one column wider: when the area
  // has no room for it, add rows instead
  while (packed.cols > maxCols && rows < count) {
    rows += 1;
    packed = pack(blockList, rows);
  }

  const perCol = new Array(packed.cols).fill(0);
  packed.slots.forEach((slot) => { perCol[slot.col] += 1; });

  // Each column is centered on the stack, then the whole grid leans
  // toward the system center: a stack high on the ring grows downward,
  // one low on the ring grows upward.
  const span = (rows - 1) * ROW_PITCH;
  let dy = -Math.sin((angle * Math.PI) / 180) * (span / 2);

  const cells = packed.slots.map(({ col, row }) => ({
    col,
    row,
    x: x0 - (col * colPitch),
    y: (row - ((perCol[col] - 1) / 2)) * ROW_PITCH,
  }));

  const minY = Math.min(...cells.map((c) => c.y));
  const maxY = Math.max(...cells.map((c) => c.y));

  // keep the tray inside the area; a grid taller than the area keeps its
  // top edge in it
  if (area) {
    const bottom = origin.y + maxY + dy + (ICON / 2) + TRAY_PAD;
    if (bottom > area.bottom - MARGIN) dy -= bottom - (area.bottom - MARGIN);
    const top = origin.y + minY + dy - (ICON / 2) - TRAY_PAD;
    if (top < area.top + MARGIN) dy += area.top + MARGIN - top;
  }

  cells.forEach((cell, index) => {
    cell.y += dy;
    cell.flip = origin
      ? origin.y + cell.y < CARD_ROOM
      : angle < -30;
    // a preview that would open under the panel left of the first area
    // opens right of the icon instead, over the grid's nearer columns
    cell.previewRight = !!origin && areas.length > 0
      && origin.x + cell.x + badgeLeft(members[index].actions || 0) - PREVIEW_REACH < areas[0].left;
  });

  // The tray backs the grid and tucks just under the stack's icon. It
  // never reaches past it: the stacks next to this one on the ring sit
  // above and below it, and must stay within reach of the pointer.
  const trayLeft = Math.min(...cells.map((c) => c.x)) + left - TRAY_PAD;
  const trayRight = -(ICON / 2) + TUCK;
  const trayTop = minY + dy - (ICON / 2) - TRAY_PAD;
  const trayBottom = maxY + dy + (ICON / 2) + TRAY_PAD;

  return {
    cells,
    tray: {
      left: trayLeft,
      top: trayTop,
      width: trayRight - trayLeft,
      height: trayBottom - trayTop,
    },
  };
}

// Formation capsules over an unfurled grid: one vertical stadium around
// each armada's icons. bands: armadaUtil.bands output ({ groupId,
// indexes }). A block only splits across columns when the grid has fewer
// rows than the armada has members; each column then gets its own piece.
export function unfurlBandPaths(bands, cells) {
  const paths = [];

  bands.forEach((band) => {
    const byCol = new Map();
    band.indexes.forEach((index) => {
      const cell = cells[index];
      if (!byCol.has(cell.col)) byCol.set(cell.col, []);
      byCol.get(cell.col).push(cell);
    });

    byCol.forEach((colCells, col) => {
      const x = colCells[0].x;
      const y0 = Math.min(...colCells.map((c) => c.y));
      const y1 = Math.max(...colCells.map((c) => c.y));
      const r = BAND_RADIUS;

      paths.push({
        key: `${band.groupId}-${col}`,
        d: [
          `M ${x - r} ${y0}`,
          `A ${r} ${r} 0 0 1 ${x + r} ${y0}`,
          `V ${y1}`,
          `A ${r} ${r} 0 0 1 ${x - r} ${y1}`,
          'Z',
        ].join(' '),
      });
    });
  });

  return paths;
}
