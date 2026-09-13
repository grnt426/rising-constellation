// Battle simulator fleet export: draws an army as a PNG card for pasting
// into chat — the fleet totals the in-game army header shows, the 6
// battle lines × 3 tiles exactly as the left rail lays them out, then a
// roster naming what the icons are. Deliberately anonymous (no player or
// side): shared designs are read by people who never saw the simulator.

import format from '@/utils/format';
import { THEME_HEX, loadIconImage } from '@/utils/image-clipboard';

const LINE_COUNT = 6;
const LINE_SIZE = 3;

// Canvas can't read SCSS: $grey steps from styles/shared/variables.scss.
const COLORS = {
  card: '#101319',
  tile: '#1b1e23', // $grey-default
  tileEdge: '#121417', // $grey-dark
  chip: '#31363f', // $grey-lighter
  text: '#e6e6e6', // $white
  muted: 'rgba(230, 230, 230, .5)',
};

const SCALE = 2; // rendered at 2× for crisp pasting on hidpi screens
const MARGIN = 14;
const TILE = 44;
const TILE_GAP = 4;
const LINE_HEADER = 18;
const LINE_GAP = 6;
const LINE_WIDTH = TILE + (TILE_GAP * 2);
const LINE_HEIGHT = LINE_HEADER + (LINE_SIZE * (TILE + TILE_GAP)) + TILE_GAP;
const GRID_WIDTH = (LINE_COUNT * LINE_WIDTH) + ((LINE_COUNT - 1) * LINE_GAP);
const STATS_TOP = 17;
const CHIP_HEIGHT = 24;
const GRID_TOP = STATS_TOP + CHIP_HEIGHT + 12;
const ROSTER_ROW = 26;

// Fleet totals as Game.Instance.Character.Army.compute_bonus sums them for
// full-hull ships: repair/raid/invasion = per-unit coef × unit count,
// upkeep = each ship's maintenance cost. `shipFor(key)` returns the ship
// data to use (the simulator passes balance-tuned data).
export function fleetStats(tiles, shipFor) {
  return tiles.reduce((acc, tile) => {
    const ship = tile && shipFor(tile.ship_key);
    if (!ship) return acc;
    acc.repair += ship.unit_repair_coef * ship.unit_count;
    acc.raid += ship.unit_raid_coef * ship.unit_count;
    acc.invasion += ship.unit_invasion_coef * ship.unit_count;
    acc.maintenance += ship.maintenance_cost;
    return acc;
  }, {
    repair: 0, raid: 0, invasion: 0, maintenance: 0,
  });
}

// Tiles show ship icons rotated a quarter turn left (.tile-icon.is-rotated).
function drawShipIcon(ctx, img, cx, cy, size) {
  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(-Math.PI / 2);
  ctx.drawImage(img, -size / 2, -size / 2, size, size);
  ctx.restore();
}

// Same corner badge as .tile-level: top-right, rounded bottom-left.
function drawLevelBadge(ctx, x, y, level) {
  const size = 16;
  ctx.fillStyle = 'rgba(0, 0, 0, .75)';
  ctx.beginPath();
  ctx.moveTo(x - size, y);
  ctx.lineTo(x, y);
  ctx.lineTo(x, y + size);
  ctx.arcTo(x - size, y + size, x - size, y, size);
  ctx.closePath();
  ctx.fill();

  ctx.fillStyle = COLORS.text;
  ctx.font = "800 10px 'Nunito', sans-serif";
  ctx.textAlign = 'center';
  ctx.fillText(String(level), x - 6, y + 10);
  ctx.textAlign = 'left';
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

// A .def-list-prop chip ("12 [icon]"). Returns its width; `alignRight`
// anchors the chip's right edge at x instead of its left.
function drawStatChip(ctx, x, y, text, icon, alignRight = false) {
  const iconSize = 14;
  ctx.font = "800 13px 'Nunito', sans-serif";
  const width = ctx.measureText(text).width + iconSize + 16;
  const left = alignRight ? x - width : x;

  ctx.fillStyle = COLORS.chip;
  roundRect(ctx, left, y, width, CHIP_HEIGHT, 5);
  ctx.fill();

  ctx.fillStyle = COLORS.text;
  ctx.fillText(text, left + 6, y + 17);
  if (icon) ctx.drawImage(icon, left + width - iconSize - 6, y + 5, iconSize, iconSize);
  return width;
}

// One roster row per (ship, level) pair, in fleet order.
function rosterOf(tiles) {
  const rows = [];
  tiles.forEach((tile) => {
    if (!tile) return;
    const row = rows.find((r) => r.ship_key === tile.ship_key && r.level === tile.level);
    if (row) {
      row.count += 1;
    } else {
      rows.push({ ship_key: tile.ship_key, level: tile.level, count: 1 });
    }
  });
  return rows;
}

// tiles: the simulator's 18-entry array of null | { ship_key, level }
// (level 0-indexed). shipFor: key -> ship data. meta: { theme, footer }
// (footer = optional muted last line, e.g. a non-default balance preset).
// Returns a PNG Blob.
export default async function renderFleetBlob(tiles, shipFor, t, meta = {}) {
  const accent = THEME_HEX[meta.theme] || THEME_HEX['dark-blue'];
  const roster = rosterOf(tiles);
  const stats = fleetStats(tiles, shipFor);

  const icons = {};
  const iconNames = [
    ...new Set(roster.map((r) => `ship/${r.ship_key}`)),
    'ship/repair', 'ship/raid', 'ship/invasion', 'resource/credit',
  ];
  await Promise.all(iconNames.map(async (name) => {
    icons[name] = await loadIconImage(name, COLORS.text, TILE * SCALE);
  }));

  const width = GRID_WIDTH + (MARGIN * 2);
  const rosterTop = GRID_TOP + LINE_HEIGHT + 16;
  const footerHeight = meta.footer ? 20 : 0;
  const height = rosterTop + (Math.max(roster.length, 1) * ROSTER_ROW) + footerHeight + MARGIN - 6;

  const canvas = document.createElement('canvas');
  canvas.width = width * SCALE;
  canvas.height = height * SCALE;
  const ctx = canvas.getContext('2d');
  ctx.scale(SCALE, SCALE);

  // card
  ctx.fillStyle = COLORS.card;
  ctx.fillRect(0, 0, width, height);
  ctx.fillStyle = accent;
  ctx.fillRect(0, 0, width, 5);
  ctx.strokeStyle = 'rgba(255, 255, 255, .12)';
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, width - 1, height - 1);
  ctx.textBaseline = 'alphabetic';

  // fleet totals, laid out like the in-game army header
  let chipX = MARGIN;
  [
    [stats.repair, 'ship/repair'],
    [stats.raid, 'ship/raid'],
    [stats.invasion, 'ship/invasion'],
  ].forEach(([value, icon]) => {
    chipX += drawStatChip(ctx, chipX, STATS_TOP, format.integer(value), icons[icon]) + 4;
  });
  drawStatChip(ctx, width - MARGIN, STATS_TOP, format.income(stats.maintenance, 0), icons['resource/credit'], true);

  // battle lines
  for (let line = 0; line < LINE_COUNT; line += 1) {
    const lineX = MARGIN + (line * (LINE_WIDTH + LINE_GAP));

    ctx.strokeStyle = COLORS.tile;
    ctx.strokeRect(lineX + 0.5, GRID_TOP + 0.5, LINE_WIDTH - 1, LINE_HEIGHT - 1);
    ctx.fillStyle = COLORS.muted;
    ctx.font = "700 10px 'Nunito', sans-serif";
    ctx.fillText(t('galaxy.selection.view.line_short', { n: line + 1 }), lineX + 5, GRID_TOP + 13);

    for (let nth = 0; nth < LINE_SIZE; nth += 1) {
      const tile = tiles[(line * LINE_SIZE) + nth];
      const x = lineX + TILE_GAP;
      const y = GRID_TOP + LINE_HEADER + TILE_GAP + (nth * (TILE + TILE_GAP));

      ctx.fillStyle = COLORS.tileEdge;
      ctx.fillRect(x, y, TILE, TILE);
      ctx.fillStyle = COLORS.tile;
      ctx.fillRect(x + 2, y + 2, TILE - 4, TILE - 4);

      if (tile) {
        const icon = icons[`ship/${tile.ship_key}`];
        if (icon) {
          drawShipIcon(ctx, icon, x + (TILE / 2), y + (TILE / 2), TILE - 6);
        } else {
          ctx.fillStyle = accent;
          ctx.beginPath();
          ctx.arc(x + (TILE / 2), y + (TILE / 2), 8, 0, Math.PI * 2);
          ctx.fill();
        }
        if (tile.level > 0) drawLevelBadge(ctx, x + TILE, y, tile.level + 1);
      }
    }
  }

  // roster
  if (roster.length === 0) {
    ctx.fillStyle = COLORS.muted;
    ctx.font = "700 13px 'Nunito', sans-serif";
    ctx.fillText(t('page.fight_simulator.export_empty'), MARGIN, rosterTop + 16);
  }

  roster.forEach((row, i) => {
    const y = rosterTop + (i * ROSTER_ROW);
    const ship = shipFor(row.ship_key);
    const icon = icons[`ship/${row.ship_key}`];

    if (icon) drawShipIcon(ctx, icon, MARGIN + 11, y + 11, 22);

    ctx.fillStyle = COLORS.text;
    ctx.font = "800 13px 'Nunito', sans-serif";
    ctx.fillText(`${row.count} × ${t(`data.ship.${row.ship_key}.name`)}`, MARGIN + 30, y + 16);

    const detail = [
      ship ? `×${ship.unit_count}` : null,
      t('page.fight_simulator.export_level', { n: row.level + 1 }),
    ].filter(Boolean).join(' · ');
    ctx.fillStyle = accent;
    ctx.font = "700 12px 'Nunito', sans-serif";
    ctx.textAlign = 'right';
    ctx.fillText(detail, width - MARGIN, y + 16);
    ctx.textAlign = 'left';
  });

  if (meta.footer) {
    ctx.fillStyle = COLORS.muted;
    ctx.font = "700 11px 'Nunito', sans-serif";
    ctx.fillText(meta.footer, MARGIN, height - MARGIN + 2);
  }

  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}
